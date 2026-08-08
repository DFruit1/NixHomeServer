import {
  $,
  component$,
  type QRL,
  useOnDocument,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError } from "./api";

export type View =
  | "overview"
  | "library"
  | "conversions"
  | "subtitles"
  | "refresh";

const VIEWS = new Set<View>([
  "overview",
  "library",
  "conversions",
  "subtitles",
  "refresh",
]);

export function viewFromSearch(search: string): View {
  const view = new URLSearchParams(search).get("view") as View | null;
  return view && VIEWS.has(view) ? view : "overview";
}

export function rootFromSearch(search: string): string {
  return new URLSearchParams(search).get("root") ?? "";
}

export function initialRouteFromSearch(search: string): RootProps {
  return {
    initialView: viewFromSearch(search),
    initialRootId: rootFromSearch(search),
  };
}

interface Integration {
  id: string;
  label: string;
  available: boolean;
  capabilities: string[];
}

export interface IntegrationRefresh {
  integrationId: string;
  state: "idle" | "queued" | "running" | "succeeded" | "failed";
  requestId?: string;
  queuedAt?: number;
  startedAt?: number;
  finishedAt?: number;
  message?: string;
}

export function refreshPresentation(status?: IntegrationRefresh): {
  label: string;
  detail: string;
  action: string;
  busy: boolean;
  tone: "idle" | "pending" | "success" | "error";
} {
  switch (status?.state) {
    case "queued":
      return {
        label: "Queued",
        detail: "Waiting for the refresh adapter to start.",
        action: "Queued",
        busy: true,
        tone: "pending",
      };
    case "running":
      return {
        label: "Refreshing…",
        detail: "The application is scanning its registered libraries.",
        action: "Working…",
        busy: true,
        tone: "pending",
      };
    case "succeeded":
      return {
        label: "Succeeded",
        detail: status.message ?? "The refresh completed successfully.",
        action: "Refresh again",
        busy: false,
        tone: "success",
      };
    case "failed":
      return {
        label: "Failed",
        detail: status.message ?? "The refresh did not complete.",
        action: "Retry",
        busy: false,
        tone: "error",
      };
    default:
      return {
        label: "Ready",
        detail: "No refresh is currently running.",
        action: "Refresh",
        busy: false,
        tone: "idle",
      };
  }
}

interface Status {
  service: string;
  mutationMode: "read-only" | "enabled";
  integrations: Integration[];
}

interface Session {
  username: string;
  groups: string[];
  canEdit: boolean;
}

interface MediaRoot {
  id: string;
  label: string;
  category: string;
  scope: "shared" | "personal";
  available: boolean;
}

interface VideoProbe {
  fps?: number;
  width?: number;
  height?: number;
  codec?: string;
  hasEmbeddedSubtitles: boolean;
  subtitleLanguages: string[];
}

interface CatalogItem {
  id: string;
  rootId: string;
  relativePath: string;
  mediaKind: string;
  sizeBytes: number;
  modifiedNs: number;
  videoProbe?: VideoProbe | null;
}

export interface TvEpisodeFields {
  title: string;
  year: string;
  season: string;
  episode: string;
  episodeTitle: string;
}

export function parseTvEpisodeFilename(
  filename: string,
): TvEpisodeFields | undefined {
  const stem = filename.replace(/\.[^./]+$/, "");
  const match = stem.match(
    /^(.*?)\s*(?:-\s*)?[Ss]([0-9]{1,3})[Ee]([0-9]{1,4})(?:\s*-\s*|\s+)?(.*)$/,
  );
  if (!match) return undefined;

  const series = match[1]
    .trim()
    .replace(/\s*-\s*$/, "")
    .trim();
  const seriesWithYear = series.match(/^(.*?)\s+\(([0-9]{4})\)$/);
  return {
    title: seriesWithYear?.[1].trim() ?? series,
    year: seriesWithYear?.[2] ?? "",
    season: match[2],
    episode: match[3],
    episodeTitle: match[4].trim().replace(/^-\s*/, ""),
  };
}

interface Conversion {
  title?: string;
  mediaKind?: string;
  percent?: number;
  detail?: string;
  sourceIso?: string;
}

interface ConversionEnvelope {
  available: boolean;
  progress: {
    state?: string;
    conversions?: Conversion[];
    queued?: string[];
  };
}

interface InboxIso {
  name: string;
  volumeId?: string | null;
  sizeBytes: number;
  modifiedNs: number;
  hasErrorLog?: boolean;
  outputDir?: string;
}

interface ConversionInbox {
  available: boolean;
  pending: InboxIso[];
  processed: InboxIso[];
  failed: InboxIso[];
  filesBaseUrl?: string;
}

interface DashboardState {
  status?: Status;
  session?: Session;
  roots: MediaRoot[];
  items: CatalogItem[];
  conversions?: ConversionEnvelope;
  selectedRootId: string;
  selectedCategory: string;
  loading: boolean;
  error: string;
  notice: string;
  selectedItemId: string;
  editProfile: NamingProfile;
  editTitle: string;
  editYear: string;
  editCreator: string;
  editCollection: string;
  editSeason: string;
  editEpisode: string;
  editEpisodeTitle: string;
  editTrack: string;
  editDisc: string;
  planning: boolean;
  confirming: boolean;
  previewSelectionKey: string;
  preview?: MutationPreview;
}

export interface RootProps {
  initialView?: View;
  initialRootId?: string;
}

type NamingProfile =
  | "movie"
  | "tv"
  | "music"
  | "audiobook"
  | "book"
  | "filename";

interface MutationPreview {
  id: string;
  digest: string;
  expiresAt: number;
  actions: Array<{
    kind?: string;
    sourceRelativePath?: string;
    destinationRelativePath: string;
  }>;
  warnings: string[];
}

const NAV_ITEMS: Array<{ id: View; label: string; icon: IconName }> = [
  { id: "overview", label: "Overview", icon: "dashboard" },
  { id: "library", label: "Libraries", icon: "library" },
  { id: "conversions", label: "Conversions", icon: "disc" },
  { id: "subtitles", label: "Subtitles", icon: "captions" },
  { id: "refresh", label: "App refresh", icon: "refresh" },
];

type IconName =
  | "dashboard"
  | "library"
  | "disc"
  | "captions"
  | "tag"
  | "refresh"
  | "shield"
  | "folder"
  | "check"
  | "alert"
  | "scan"
  | "arrow"
  | "image"
  | "chevron-down"
  | "chevron-right";

const Icon = component$<{ name: IconName; size?: number }>((props) => {
  const paths: Record<IconName, string[]> = {
    dashboard: [
      "M4 4h6v6H4z",
      "M14 4h6v10h-6z",
      "M4 14h6v6H4z",
      "M14 18h6v2h-6z",
    ],
    library: ["M4 5h5l2 2h9v12H4z", "M4 9h16"],
    disc: [
      "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z",
      "M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z",
      "m16.5 7.5-2.2 2.2",
    ],
    captions: ["M4 5h16v14H4z", "M8 10h3", "M8 14h3", "M13 10h3", "M13 14h3"],
    tag: ["M20 13 13 20 4 11V4h7z", "M8.5 8.5h.01"],
    refresh: [
      "M20 6v5h-5",
      "M4 18v-5h5",
      "M18.3 9A7 7 0 0 0 6.7 6.7L4 11",
      "M5.7 15A7 7 0 0 0 17.3 17.3L20 13",
    ],
    shield: [
      "M12 3 5 6v5c0 4.6 2.8 8 7 10 4.2-2 7-5.4 7-10V6z",
      "m9 12 2 2 4-4",
    ],
    folder: ["M3 6h7l2 2h9v11H3z"],
    check: ["m5 12 4 4L19 6"],
    alert: ["M12 4 3 20h18z", "M12 9v4", "M12 17h.01"],
    scan: ["M4 8V4h4", "M16 4h4v4", "M20 16v4h-4", "M8 20H4v-4", "M8 12h8"],
    arrow: ["M5 12h14", "m14 7 5 5-5 5"],
    image: ["M4 5h16v14H4z", "m4 15 4.5-4.5 3.5 3.5 3-3L20 16", "M9.5 9.5h.01"],
    "chevron-down": ["m6 9 6 6 6-6"],
    "chevron-right": ["m9 6 6 6-6 6"],
  };
  return (
    <svg
      aria-hidden="true"
      class="icon"
      width={props.size ?? 20}
      height={props.size ?? 20}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      {paths[props.name].map((path) => (
        <path d={path} key={path} />
      ))}
    </svg>
  );
});

export default component$((props: RootProps) => {
  const view = useSignal<View>(props.initialView ?? "overview");
  const sidebarSide = useSignal<"left" | "right">("left");
  const menuOpen = useSignal(false);
  const state = useStore<DashboardState>({
    roots: [],
    items: [],
    selectedRootId: "",
    selectedCategory: "",
    loading: true,
    error: "",
    notice: "",
    selectedItemId: "",
    editProfile: "movie",
    editTitle: "",
    editYear: "",
    editCreator: "",
    editCollection: "",
    editSeason: "",
    editEpisode: "",
    editEpisodeTitle: "",
    editTrack: "",
    editDisc: "",
    planning: false,
    confirming: false,
    previewSelectionKey: "",
  });

  // eslint-disable-next-line qwik/no-use-visible-task -- sidebar preference is client-only
  useVisibleTask$(() => {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem("mm-sidebar-side");
      if (saved === "right" || saved === "left") sidebarSide.value = saved;
    }
  });

  const toggleSidebarSide = $(() => {
    sidebarSide.value = sidebarSide.value === "left" ? "right" : "left";
    if (typeof localStorage !== "undefined") {
      localStorage.setItem("mm-sidebar-side", sidebarSide.value);
    }
    menuOpen.value = false;
  });

  useOnDocument(
    "click",
    $((e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest(".sidebar-footer") && menuOpen.value) {
        menuOpen.value = false;
      }
    }),
  );

  const loadCategoryItems = $(async (category: string) => {
    const categoryRoots = state.roots.filter(
      (root) => root.category === category,
    );
    state.selectedCategory = category;
    state.error = "";
    try {
      const results = await Promise.all(
        categoryRoots.map((root) =>
          api<{ items: CatalogItem[] }>(
            `/items?rootId=${encodeURIComponent(root.id)}`,
          ),
        ),
      );
      state.items = results.flatMap((result) => result.items);
    } catch (error) {
      state.error = readableError(error);
    }
  });

  useTask$(async () => {
    try {
      const [status, session, roots, conversions] = await Promise.all([
        api<Status>("/status"),
        api<Session>("/session"),
        api<MediaRoot[]>("/roots"),
        api<ConversionEnvelope>("/conversions"),
      ]);
      state.status = status;
      state.session = session;
      state.roots = roots;
      state.conversions = conversions;
      const requestedRoot = roots.find(
        (root) => root.id === props.initialRootId,
      );
      const selectedRoot = requestedRoot ?? roots[0];
      state.selectedRootId = selectedRoot?.id ?? "";
      state.selectedCategory = selectedRoot?.category ?? "";
      if (view.value === "library" && selectedRoot) {
        await loadCategoryItems(selectedRoot.category);
      }
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });

  const selectItem = $((item: CatalogItem) => {
    state.selectedItemId = item.id;
    const category = state.roots.find(
      (root) => root.id === item.rootId,
    )?.category;
    const filename = item.relativePath.split("/").at(-1) ?? item.relativePath;
    const tvEpisode =
      category === "videos" ? parseTvEpisodeFilename(filename) : undefined;
    state.editProfile = tvEpisode ? "tv" : profileForCategory(category);
    state.editTitle =
      tvEpisode?.title ??
      filename.replace(/\.[A-Za-z0-9]+$/, "").replace(/ \([0-9]{4}\)$/, "");
    state.editYear =
      tvEpisode?.year ??
      filename.match(/ \(([0-9]{4})\)(?:\.[^.]+)?$/)?.[1] ??
      "";
    state.editCreator = "";
    state.editCollection = "";
    state.editSeason = tvEpisode?.season ?? "";
    state.editEpisode = tvEpisode?.episode ?? "";
    state.editEpisodeTitle = tvEpisode?.episodeTitle ?? "";
    state.editTrack =
      filename.match(/^(?:[0-9]+-)?([0-9]{1,3})\s+-\s+/)?.[1] ?? "";
    state.editDisc = filename.match(/^([0-9]+)-[0-9]{1,3}\s+-\s+/)?.[1] ?? "";
    state.preview = undefined;
    state.notice = "";
  });

  const previewRename = $(async () => {
    if (!state.selectedItemId || !renameReady(state)) return;
    state.planning = true;
    state.error = "";
    state.notice = "";
    try {
      const year = state.editYear.trim();
      const operation: Record<string, string | number | boolean> = {
        kind: "canonicalize_names",
        profile: state.editProfile,
        organizeFolders: true,
        title: state.editTitle.trim(),
      };
      if (year) operation.year = Number.parseInt(year, 10);
      if (state.editProfile === "tv") {
        operation.season = Number.parseInt(state.editSeason, 10);
        operation.episode = Number.parseInt(state.editEpisode, 10);
        if (state.editEpisodeTitle.trim()) {
          operation.episodeTitle = state.editEpisodeTitle.trim();
        }
      } else if (state.editProfile === "music") {
        operation.artist = state.editCreator.trim();
        operation.album = state.editCollection.trim();
        operation.track = Number.parseInt(state.editTrack, 10);
        if (state.editDisc)
          operation.disc = Number.parseInt(state.editDisc, 10);
      } else if (["audiobook", "book"].includes(state.editProfile)) {
        operation.author = state.editCreator.trim();
        if (state.editCollection.trim()) {
          operation.series = state.editCollection.trim();
        }
      }
      state.preview = await api<MutationPreview>("/plans", {
        method: "POST",
        body: JSON.stringify({ operation, itemIds: [state.selectedItemId] }),
      });
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.planning = false;
    }
  });

  const confirmRename = $(async () => {
    if (!state.preview || state.confirming) return;
    state.confirming = true;
    state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(state.preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${state.preview.digest}"` },
      });
      state.notice = "The rename was added to the global mutation queue.";
      state.preview = undefined;
      state.selectedItemId = "";
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.confirming = false;
    }
  });

  const currentConversions = state.conversions?.progress.conversions ?? [];
  return (
    <div
      class={{
        "app-shell": true,
        "sidebar-right": sidebarSide.value === "right",
      }}
    >
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <div>
            <strong>Media Manager</strong>
            <span>Library control</span>
          </div>
        </div>

        <nav aria-label="Media Manager sections">
          {NAV_ITEMS.map((item) => (
            <a
              key={item.id}
              href={`?view=${item.id}`}
              class={{ "nav-item": true, active: view.value === item.id }}
              aria-current={view.value === item.id ? "page" : undefined}
              title={item.label}
            >
              <Icon name={item.icon} />
              <span>{item.label}</span>
            </a>
          ))}
        </nav>

        <div class="sidebar-footer">
          <div style={{ position: "relative" }}>
            <div
              class="avatar"
              role="button"
              tabIndex={0}
              aria-label="User menu"
              onClick$={() => (menuOpen.value = !menuOpen.value)}
              onKeyDown$={(e: KeyboardEvent) => {
                if (e.key === "Enter" || e.key === " ") {
                  menuOpen.value = !menuOpen.value;
                }
              }}
            >
              {(state.session?.username ?? "?").slice(0, 1).toUpperCase()}
            </div>
            {menuOpen.value && (
              <div class="user-menu">
                <button
                  type="button"
                  class="user-menu-item"
                  onClick$={toggleSidebarSide}
                >
                  {sidebarSide.value === "left"
                    ? "Move sidebar to right"
                    : "Move sidebar to left"}
                </button>
              </div>
            )}
          </div>
          <div>
            <strong>{state.session?.username ?? "Loading…"}</strong>
            <span>{state.session?.canEdit ? "Editor" : "Viewer"}</span>
          </div>
          <span
            class={{ "role-dot": true, editor: state.session?.canEdit }}
            title={state.session?.canEdit ? "Editor access" : "Viewer access"}
          />
        </div>
      </aside>

      <main class="main-content">
        {view.value !== "library" && (
          <header class="topbar">
            <h1>{NAV_ITEMS.find((item) => item.id === view.value)?.label}</h1>
          </header>
        )}

        {state.error && (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{state.error}</span>
            <button
              type="button"
              aria-label="Dismiss error"
              onClick$={() => (state.error = "")}
            >
              ×
            </button>
          </div>
        )}
        {state.notice && (
          <div class="message success" role="status">
            <Icon name="check" size={18} />
            <span>{state.notice}</span>
          </div>
        )}

        {state.loading ? (
          <LoadingState />
        ) : view.value === "overview" ? (
          <OverviewSection state={state} />
        ) : view.value === "library" ? (
          <LibraryView
            state={state}
            selectItem$={selectItem}
            previewRename$={previewRename}
            confirmRename$={confirmRename}
            loadCategoryItems$={loadCategoryItems}
          />
        ) : view.value === "conversions" ? (
          <ConversionsView initial={state.conversions} />
        ) : view.value === "subtitles" ? (
          <SubtitleView
            roots={state.roots}
            session={state.session}
            status={state.status}
          />
        ) : (
          <RefreshView integrations={state.status?.integrations ?? []} />
        )}
      </main>
    </div>
  );
});

const OverviewSection = component$<{
  state: DashboardState;
}>((props) => {
  const videoRoots = props.state.roots.filter(
    (root) => root.category === "videos",
  );
  const musicRoots = props.state.roots.filter(
    (root) => root.category === "music",
  );
  const audiobookRoots = props.state.roots.filter(
    (root) => root.category === "audiobooks",
  );
  const bookRoots = props.state.roots.filter(
    (root) => root.category === "books",
  );

  const buildOverviewItems = (roots: MediaRoot[]): OverviewItem[] => {
    const items: OverviewItem[] = [];
    for (const root of roots) {
      const rootItems = props.state.items.filter(
        (item) => item.rootId === root.id,
      );
      for (const item of rootItems.slice(0, 12)) {
        const filename = item.relativePath.split("/").at(-1) ?? "";
        const stem = filename.replace(/\.[^.]+$/, "");
        const title = stem
          .replace(/ \(([0-9]{4})\)$/, "")
          .replace(/ - S[0-9]+E[0-9]+.*$/, "");
        const yearMatch = filename.match(/ \(([0-9]{4})\)$/);
        const subtitle = yearMatch ? yearMatch[1] : root.label;
        items.push({
          id: item.id,
          title,
          subtitle,
          imageId: item.id,
          rootId: item.rootId,
        });
      }
    }
    return items;
  };

  const videoItems = buildOverviewItems(videoRoots);
  const musicItems = buildOverviewItems(musicRoots);
  const audiobookItems = buildOverviewItems(audiobookRoots);
  const bookItems = buildOverviewItems(bookRoots);

  return (
    <section class="overview-carousels" aria-label="Media library overview">
      {videoItems.length > 0 && (
        <CategoryCarousel
          title="Videos"
          items={videoItems}
          href="?view=library"
        />
      )}
      {musicItems.length > 0 && (
        <CategoryCarousel
          title="Music"
          items={musicItems}
          href="?view=library"
        />
      )}
      {audiobookItems.length > 0 && (
        <CategoryCarousel
          title="Audiobooks"
          items={audiobookItems}
          href="?view=library"
        />
      )}
      {bookItems.length > 0 && (
        <CategoryCarousel
          title="Books"
          items={bookItems}
          href="?view=library"
        />
      )}
      {videoItems.length === 0 &&
        musicItems.length === 0 &&
        audiobookItems.length === 0 &&
        bookItems.length === 0 && (
          <EmptyState
            title="No media found"
            detail="Add media roots and scan to see your library here."
          />
        )}
    </section>
  );
});

interface OverviewItem {
  id: string;
  title: string;
  subtitle: string;
  imageId: string;
  rootId: string;
}

const CategoryCarousel = component$<{
  title: string;
  items: OverviewItem[];
  href: string;
}>((props) => {
  return (
    <section class="panel category-carousel">
      <div class="panel-heading">
        <div>
          <h3>{props.title}</h3>
        </div>
        <a class="text-button" href={props.href}>
          View all <Icon name="arrow" size={17} />
        </a>
      </div>
      <div class="carousel-scroll-region">
        {props.items.length === 0 ? (
          <div class="carousel-empty">
            <span>No items in this category</span>
          </div>
        ) : (
          <div class="carousel-track">
            {props.items.map((item) => (
              <a
                class="carousel-item"
                href={`?view=library&root=${encodeURIComponent(item.rootId)}`}
                key={item.id}
              >
                <div class="carousel-item-image">
                  {item.imageId ? (
                    <img
                      src={`/api/v1/items/${encodeURIComponent(item.imageId)}/image`}
                      alt={item.title}
                      loading="lazy"
                    />
                  ) : (
                    <div class="carousel-item-placeholder">
                      <Icon name="image" size={24} />
                    </div>
                  )}
                </div>
                <div class="carousel-item-info">
                  <strong>{item.title}</strong>
                  <small>{item.subtitle}</small>
                </div>
              </a>
            ))}
          </div>
        )}
      </div>
    </section>
  );
});

const SubtitleCard = component$<{
  items: CatalogItem[];
  selectedItemId: string;
}>((props) => {
  const selectedItem = props.items.find(
    (item) => item.id === props.selectedItemId,
  );
  if (!selectedItem) {
    return (
      <div class="subtitle-card-body">
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>Select a file to inspect its subtitles.</span>
        </div>
      </div>
    );
  }
  if (selectedItem.mediaKind !== "video") {
    return (
      <div class="subtitle-card-body">
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>Subtitles are only listed for video files.</span>
        </div>
      </div>
    );
  }
  const selectedItemPath = selectedItem.relativePath;
  const selectedDir = selectedItemPath.substring(
    0,
    selectedItemPath.lastIndexOf("/"),
  );
  const videoStem =
    selectedItemPath
      .split("/")
      .at(-1)
      ?.replace(/\.[^.]+$/, "") ?? "";
  const subtitles = props.items.filter((item) => {
    if (item.mediaKind !== "subtitle") return false;
    if (item.rootId !== selectedItem.rootId) return false;
    const itemDir = item.relativePath.substring(
      0,
      item.relativePath.lastIndexOf("/"),
    );
    if (itemDir !== selectedDir) return false;
    const subtitleName = item.relativePath.split("/").at(-1) ?? "";
    const subtitleStem = subtitleName.replace(/\.[^.]+$/, "");
    return (
      subtitleStem === videoStem ||
      subtitleStem.startsWith(`${videoStem}.`) ||
      videoStem.startsWith(`${subtitleStem}.`)
    );
  });
  return (
    <div class="subtitle-card-body">
      {subtitles.length === 0 ? (
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>No subtitles found for this file</span>
        </div>
      ) : (
        <ul class="subtitle-list">
          {subtitles.map((sub) => {
            const filename = sub.relativePath.split("/").at(-1) ?? "";
            const ext = filename.split(".").at(-1)?.toUpperCase() ?? "";
            const langMatch = filename.match(
              /\.(?:en|es|fr|de|it|pt|ja|ko|zh|ru|ar|hi)\b/i,
            );
            const lang = langMatch ? langMatch[0].slice(1).toUpperCase() : ext;
            return (
              <li class="subtitle-item" key={sub.id}>
                <span class="subtitle-lang">{lang}</span>
                <span class="subtitle-filename">{filename}</span>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
});

interface TreeNode {
  name: string;
  path: string;
  item?: CatalogItem;
  children: TreeNode[];
}

function buildTree(items: CatalogItem[]): TreeNode[] {
  const roots: TreeNode[] = [];
  const folders = new Map<string, TreeNode>();
  for (const item of [...items].sort((a, b) =>
    a.relativePath.localeCompare(b.relativePath),
  )) {
    const segments = item.relativePath.split("/");
    let path = "";
    let siblings = roots;
    for (let index = 0; index < segments.length - 1; index += 1) {
      path = path ? `${path}/${segments[index]}` : segments[index];
      let folder = folders.get(path);
      if (!folder) {
        folder = { name: segments[index], path, children: [] };
        folders.set(path, folder);
        siblings.push(folder);
      }
      siblings = folder.children;
    }
    siblings.push({
      name: segments[segments.length - 1],
      path: item.relativePath,
      item,
      children: [],
    });
  }
  const sortBranch = (nodes: TreeNode[]): TreeNode[] =>
    nodes
      .map((node) => ({ ...node, children: sortBranch(node.children) }))
      .sort((left, right) => {
        const folderDelta =
          Number(Boolean(right.children.length || !right.item)) -
          Number(Boolean(left.children.length || !left.item));
        return folderDelta || left.name.localeCompare(right.name);
      });
  return sortBranch(roots);
}

function topLevelFolders(items: CatalogItem[]): string[] {
  const folders = new Set<string>();
  for (const item of items) {
    const slash = item.relativePath.indexOf("/");
    if (slash > 0) folders.add(item.relativePath.slice(0, slash));
  }
  return [...folders].sort((left, right) => left.localeCompare(right));
}

function folderDisplayName(folder: string): string {
  return folder.replace(/^_+/, "") || folder;
}

function artworkCandidateId(
  items: CatalogItem[],
  selectedItemId: string,
  selectedFolder: string,
): string {
  if (selectedItemId) return selectedItemId;
  if (!selectedFolder) return "";
  const prefix = `${selectedFolder}/`;
  const inside = items.filter((item) => item.relativePath.startsWith(prefix));
  return (
    inside.find((item) => item.mediaKind !== "artwork")?.id ??
    inside.find((item) => item.mediaKind === "artwork")?.id ??
    inside[0]?.id ??
    ""
  );
}

const MediaImage = component$<{
  imageId: string;
  title: string;
}>(
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  (props) => {
    const failed = useSignal(false);
    useTask$(({ track }) => {
      track(() => props.imageId);
      failed.value = false;
    });
    return (
      <figure class="media-image">
        {props.imageId && !failed.value ? (
          <img
            src={`/api/v1/items/${encodeURIComponent(props.imageId)}/image`}
            alt={`Cover artwork for ${props.title}`}
            loading="lazy"
            onError$={() => (failed.value = true)}
          />
        ) : (
          <div class="media-image-placeholder" aria-hidden="true">
            <Icon name="image" size={30} />
          </div>
        )}
      </figure>
    );
  },
);

const ArtworkFileCard = component$<{
  item: CatalogItem;
  state: DashboardState;
}>((props) => {
  const uploadInput = useSignal<HTMLInputElement>();
  const replacement = useStore<{
    uploading: boolean;
    confirming: boolean;
    error: string;
    notice: string;
    previewItemId: string;
    preview?: MutationPreview;
  }>({
    uploading: false,
    confirming: false,
    error: "",
    notice: "",
    previewItemId: "",
  });
  useTask$(({ track }) => {
    track(() => props.item.id);
    replacement.uploading = false;
    replacement.confirming = false;
    replacement.error = "";
    replacement.notice = "";
    replacement.previewItemId = "";
    replacement.preview = undefined;
  });
  const confirmReplacement = $(async () => {
    if (
      !replacement.preview ||
      replacement.previewItemId !== props.item.id ||
      replacement.confirming
    )
      return;
    const itemId = props.item.id;
    const preview = replacement.preview;
    replacement.confirming = true;
    replacement.error = "";
    try {
      await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${preview.digest}"` },
      });
      if (props.item.id !== itemId) return;
      replacement.notice =
        "The cover replacement was added to the mutation queue.";
      replacement.previewItemId = "";
      replacement.preview = undefined;
    } catch (error) {
      if (props.item.id === itemId) replacement.error = readableError(error);
    } finally {
      if (props.item.id === itemId) replacement.confirming = false;
    }
  });
  return (
    <section class="panel editor-card non-media-card">
      <div class="editor-heading">
        <div class="non-media-heading">
          <Icon name="image" size={18} />
          <h3>Image File (Cover Art)</h3>
        </div>
        <button
          class="close-button"
          type="button"
          aria-label="Close image details"
          onClick$={() => (props.state.selectedItemId = "")}
        >
          ×
        </button>
      </div>
      <div class="non-media-body">
        <p>
          This image is used as nearby cover art. It does not have editable
          media metadata of its own.
        </p>
        <code>{props.item.relativePath}</code>
        <input
          ref={uploadInput}
          class="visually-hidden"
          type="file"
          accept=".jpg,.jpeg,.png,.gif,.webp,image/jpeg,image/png,image/gif,image/webp"
          onChange$={async (_, input) => {
            const file = input.files?.[0];
            if (!file || replacement.uploading) return;
            const itemId = props.item.id;
            const format = file.name.split(".").at(-1)?.toLowerCase() ?? "";
            replacement.uploading = true;
            replacement.error = "";
            replacement.notice = "";
            replacement.previewItemId = "";
            replacement.preview = undefined;
            try {
              const preview = await api<MutationPreview>(
                `/items/${encodeURIComponent(itemId)}/image/replacement?${new URLSearchParams({ format })}`,
                {
                  method: "POST",
                  headers: {
                    "content-type": file.type || "application/octet-stream",
                  },
                  body: file,
                },
              );
              if (props.item.id === itemId) {
                replacement.previewItemId = itemId;
                replacement.preview = preview;
              }
            } catch (error) {
              if (props.item.id === itemId)
                replacement.error = readableError(error);
            } finally {
              if (props.item.id === itemId) replacement.uploading = false;
              input.value = "";
            }
          }}
        />
        <button
          class="secondary-button"
          type="button"
          disabled={!props.state.session?.canEdit || replacement.uploading}
          onClick$={() => uploadInput.value?.click()}
        >
          <Icon name="image" size={18} />
          {replacement.uploading
            ? "Preparing replacement…"
            : "Replace cover art"}
        </button>
        {replacement.preview && (
          <div class="non-media-confirm">
            <p>
              The current file will move into a <code>superseded</code>
              subfolder before the new image is installed.
            </p>
            <button
              class="primary-button"
              type="button"
              disabled={
                props.state.status?.mutationMode !== "enabled" ||
                replacement.confirming
              }
              onClick$={confirmReplacement}
            >
              <Icon name="check" size={18} />
              {replacement.confirming ? "Queuing…" : "Confirm replacement"}
            </button>
          </div>
        )}
        {replacement.error && <p class="error-copy">{replacement.error}</p>}
        {replacement.notice && (
          <p class="success-copy" role="status">
            {replacement.notice}
          </p>
        )}
      </div>
    </section>
  );
});

const CATEGORY_TABS: Array<{ id: string; label: string; icon: IconName }> = [
  { id: "videos", label: "Videos", icon: "image" },
  { id: "music", label: "Music", icon: "disc" },
  { id: "audiobooks", label: "Audiobooks", icon: "captions" },
  { id: "books", label: "Books", icon: "library" },
];

const LibraryPane = component$<{
  title: string;
  subtitle: string;
  browser: {
    expanded: Record<string, boolean>;
    activeByParent: Record<string, string>;
    folderFilter: string;
    selectedFolder: string;
  };
  items: CatalogItem[];
  selectedItemId: string;
  selectItem$: QRL<(item: CatalogItem) => void>;
  selectFolder$: QRL<(path: string) => void>;
}>((props) => {
  const folders = topLevelFolders(props.items);
  const visibleItems = props.browser.folderFilter
    ? props.items.filter((item) =>
        item.relativePath.startsWith(`${props.browser.folderFilter}/`),
      )
    : props.items;
  const tree = buildTree(visibleItems);
  return (
    <section
      class={{
        panel: true,
        "catalog-panel": true,
        "personal-pane": props.title === "Personal",
        "shared-pane": props.title === "Shared",
      }}
    >
      <div class="pane-heading">
        <h3>{props.title}</h3>
        <span class="pane-count">{props.items.length}</span>
      </div>
      <div class="catalog-scroll-region">
        {props.items.length === 0 ? (
          <EmptyState
            title={props.subtitle}
            detail="This directory has been cataloged but does not currently contain supported media files."
          />
        ) : (
          <>
            {folders.length > 1 && (
              <div
                class="folder-filter"
                role="group"
                aria-label="Show only one folder"
              >
                {folders.map((folder) => (
                  <button
                    class={{
                      "folder-filter-button": true,
                      active: props.browser.folderFilter === folder,
                    }}
                    type="button"
                    key={folder}
                    aria-pressed={props.browser.folderFilter === folder}
                    onClick$={() => {
                      props.browser.folderFilter =
                        props.browser.folderFilter === folder ? "" : folder;
                    }}
                  >
                    {folderDisplayName(folder)}
                  </button>
                ))}
              </div>
            )}
            <div
              class="item-tree"
              role="tree"
              aria-label={`${props.title} items`}
            >
              {tree.map((node) => (
                <TreeBranch
                  node={node}
                  depth={0}
                  browser={props.browser}
                  selectedItemId={props.selectedItemId}
                  selectedFolder={props.browser.selectedFolder}
                  selectItem$={props.selectItem$}
                  selectFolder$={props.selectFolder$}
                  parentPath=""
                  siblingPaths={tree
                    .filter((sibling) => !sibling.item)
                    .map((sibling) => sibling.path)}
                  key={node.path}
                />
              ))}
            </div>
          </>
        )}
      </div>
    </section>
  );
});

const LibraryView = component$<{
  state: DashboardState;
  selectItem$: QRL<(item: CatalogItem) => void>;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
  loadCategoryItems$: QRL<(category: string) => Promise<void>>;
}>((props) => {
  const personal = useStore({
    expanded: {} as Record<string, boolean>,
    activeByParent: {} as Record<string, string>,
    folderFilter: "",
    selectedFolder: "",
  });
  const shared = useStore({
    expanded: {} as Record<string, boolean>,
    activeByParent: {} as Record<string, string>,
    folderFilter: "",
    selectedFolder: "",
  });
  useTask$(({ track }) => {
    track(() => props.state.selectedCategory);
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const libraryRoots = props.state.roots.filter(
    (root) => root.category !== "iso",
  );
  const activeCategory = props.state.selectedCategory;
  const categoryRoots = libraryRoots.filter(
    (root) => root.category === activeCategory,
  );
  const personalRoots = categoryRoots.filter(
    (root) => root.scope === "personal",
  );
  const sharedRoots = categoryRoots.filter((root) => root.scope === "shared");
  const personalItems = props.state.items.filter((item) =>
    personalRoots.some((root) => root.id === item.rootId),
  );
  const sharedItems = props.state.items.filter((item) =>
    sharedRoots.some((root) => root.id === item.rootId),
  );
  const selectedItem = props.state.items.find(
    (item) => item.id === props.state.selectedItemId,
  );
  const activeFolder = personal.selectedFolder || shared.selectedFolder;
  const imageTitle =
    selectedItem?.relativePath.split("/").at(-1) ??
    (activeFolder
      ? folderDisplayName(activeFolder.split("/").at(-1) ?? "")
      : "");
  const activeFolderItems = personal.selectedFolder
    ? personalItems
    : sharedItems;
  const activeFolderRootId = activeFolderItems.find((item) =>
    item.relativePath.startsWith(`${activeFolder}/`),
  )?.rootId;
  const selectPersonalFolder$ = $((path: string) => {
    personal.selectedFolder = path;
    shared.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const selectSharedFolder$ = $((path: string) => {
    shared.selectedFolder = path;
    personal.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const selectPersonalItem$ = $((item: CatalogItem) => {
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.selectItem$(item);
  });
  const selectSharedItem$ = $((item: CatalogItem) => {
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.selectItem$(item);
  });
  const closeFolderEditor$ = $(() => {
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.state.preview = undefined;
    props.state.notice = "";
  });
  return (
    <section class="library-layout">
      <div class="library-tabs" role="tablist" aria-label="Media categories">
        {CATEGORY_TABS.map((tab) => {
          const hasRoots = libraryRoots.some(
            (root) => root.category === tab.id,
          );
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={activeCategory === tab.id}
              class={{
                "library-tab": true,
                active: activeCategory === tab.id,
                disabled: !hasRoots,
              }}
              disabled={!hasRoots}
              onClick$={() => props.loadCategoryItems$(tab.id)}
            >
              <Icon name={tab.icon} size={17} />
              {tab.label}
            </button>
          );
        })}
      </div>
      <LibraryPane
        title="Personal"
        subtitle="No personal media files found"
        browser={personal}
        items={personalItems}
        selectedItemId={props.state.selectedItemId}
        selectItem$={selectPersonalItem$}
        selectFolder$={selectPersonalFolder$}
      />
      <LibraryPane
        title="Shared"
        subtitle="No shared media files found"
        browser={shared}
        items={sharedItems}
        selectedItemId={props.state.selectedItemId}
        selectItem$={selectSharedItem$}
        selectFolder$={selectSharedFolder$}
      />
      {(selectedItem || activeFolder) && (
        <div class="root-picker-image">
          <MediaImage
            imageId={artworkCandidateId(
              props.state.items,
              props.state.selectedItemId,
              activeFolder,
            )}
            title={imageTitle}
          />
        </div>
      )}
      {selectedItem &&
        ["video", "music", "audiobook", "book"].includes(
          selectedItem.mediaKind,
        ) && (
          <ItemEditor
            state={props.state}
            previewRename$={props.previewRename$}
            confirmRename$={props.confirmRename$}
          />
        )}
      {selectedItem?.mediaKind === "artwork" && (
        <ArtworkFileCard item={selectedItem} state={props.state} />
      )}
      {!selectedItem && activeFolder && activeFolderRootId && (
        <ItemEditor
          state={props.state}
          previewRename$={props.previewRename$}
          confirmRename$={props.confirmRename$}
          folder={{
            rootId: activeFolderRootId,
            relativePath: activeFolder,
          }}
          close$={closeFolderEditor$}
        />
      )}
    </section>
  );
});

const TreeBranch = component$<{
  node: TreeNode;
  depth: number;
  browser: {
    expanded: Record<string, boolean>;
    activeByParent: Record<string, string>;
    selectedFolder: string;
    folderFilter: string;
  };
  selectedItemId: string;
  selectedFolder: string;
  selectItem$: QRL<(item: CatalogItem) => void>;
  selectFolder$: QRL<(path: string) => void>;
  parentPath: string;
  siblingPaths: string[];
}>((props) => {
  const node = props.node;
  if (node.item) {
    return (
      <button
        class={{
          "tree-row": true,
          file: true,
          selected: props.selectedItemId === node.item.id,
        }}
        style={{ paddingLeft: `${14 + props.depth * 16}px` }}
        role="treeitem"
        type="button"
        onClick$={() => {
          props.browser.selectedFolder = "";
          props.selectItem$(node.item as CatalogItem);
        }}
      >
        <span class="tree-name">{node.name}</span>
        <span class="tabular muted">{formatBytes(node.item.sizeBytes)}</span>
      </button>
    );
  }
  const expanded =
    props.browser.expanded[node.path] ??
    (props.depth === 0 || props.browser.folderFilter !== "");
  const mutedBySibling =
    Boolean(props.browser.activeByParent[props.parentPath]) &&
    props.browser.activeByParent[props.parentPath] !== node.path;
  return (
    <div class="tree-branch" role="treeitem" aria-expanded={expanded}>
      <div
        class={{
          "tree-row": true,
          folder: true,
          selected: props.selectedFolder === node.path,
          "sibling-muted": mutedBySibling,
        }}
        style={{ paddingLeft: `${14 + props.depth * 16}px` }}
      >
        <button
          class="tree-toggle"
          type="button"
          aria-label={`${expanded ? "Collapse" : "Expand"} ${node.name}`}
          onClick$={(_, currentTarget) => {
            const willExpand = !expanded;
            props.browser.expanded[node.path] = willExpand;
            if (willExpand) {
              for (const siblingPath of props.siblingPaths) {
                props.browser.expanded[siblingPath] = siblingPath === node.path;
              }
              props.browser.activeByParent[props.parentPath] = node.path;
              const tree = currentTarget.closest(
                ".item-tree",
              ) as HTMLElement | null;
              if (tree) tree.scrollTop = 0;
            } else if (
              props.browser.activeByParent[props.parentPath] === node.path
            ) {
              props.browser.activeByParent[props.parentPath] = "";
            }
          }}
        >
          <Icon name={expanded ? "chevron-down" : "chevron-right"} size={15} />
        </button>
        <button
          class="tree-folder-name"
          type="button"
          onClick$={() => props.selectFolder$(node.path)}
        >
          <span class="tree-name">{node.name}</span>
        </button>
      </div>
      {expanded && (
        <div role="group">
          {node.children.map((child) => (
            <TreeBranch
              node={child}
              depth={props.depth + 1}
              browser={props.browser}
              selectedItemId={props.selectedItemId}
              selectedFolder={props.selectedFolder}
              selectItem$={props.selectItem$}
              selectFolder$={props.selectFolder$}
              parentPath={node.path}
              siblingPaths={node.children
                .filter((sibling) => !sibling.item)
                .map((sibling) => sibling.path)}
              key={child.path}
            />
          ))}
        </div>
      )}
    </div>
  );
});

const ConversionList = component$<{
  conversion: Conversion;
  queuedEntry: QueuedConversion[];
  expanded?: boolean;
}>((props) => {
  const hasQueued = props.queuedEntry.length > 0;
  const hasActive = !!(props.conversion?.title || props.conversion?.sourceIso);
  if (!hasActive && !hasQueued) {
    return (
      <EmptyState
        title="No ISO files being converted"
        detail="Drop an ISO into the shared inbox to start a conversion."
      />
    );
  }
  const percent = Math.max(
    0,
    Math.min(100, props.conversion.percent ?? 0),
  );
  const isoName = props.conversion.sourceIso ?? "";
  return (
    <div class={{ "conversion-list": true, expanded: props.expanded }}>
      {props.conversion.title && (
        <article class="conversion-card">
          <div class="disc-visual">
            <span />
            <span />
          </div>
          <div class="conversion-copy">
            <h4>{props.conversion.title}</h4>
            <p>Converting {isoName}{" "}
              {props.conversion.detail
                ? `— ${props.conversion.detail}`
                : "— Encoding a Jellyfin-compatible MKV"}
            </p>
            <div class="progress-track" aria-label={`${percent}% complete`}>
              <span style={{ width: `${percent}%` }} />
            </div>
            <div class="progress-meta">
              <span>Converting</span>
              <strong class="tabular">{percent.toFixed(0)}%</strong>
            </div>
          </div>
        </article>
      )}
      {hasQueued && (
        <div
          class="conversion-queue"
          aria-label={`${props.queuedEntry.length} DVD discs waiting`}
        >
          <span class="conversion-queue__heading">
            In queue ({props.queuedEntry.length})
          </span>
          <ol class="conversion-queue__list">
            {props.queuedEntry.map((item, index) => (
              <li key={`${item.isoName}-${index}`}>
                <span class="conversion-queue__number">{index + 1}.</span>
                <span class="conversion-queue__title" title={item.isoName}>
                  {item.title}{" "}
                  <span class="conversion-queue__file">
                    ({item.isoName})
                  </span>
                </span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
});

interface QueuedConversion {
  title: string;
  isoName: string;
}

const LogDialog = component$<{
  isoName: string;
  onClose$: QRL<() => void>;
}>((props) => {
  const log = useSignal<string>("");
  const loading = useSignal(true);
  const error = useSignal("");

  useTask$(() => {
    const load = async () => {
      try {
        log.value = (
          await api<{ content: string }>(
            `/conversions/inbox/error?name=${encodeURIComponent(props.isoName)}`,
          )
        ).content;
      } catch (e) {
        error.value = readableError(e);
      } finally {
        loading.value = false;
      }
    };
    void load();
  });

  return (
    <div class="dialog-backdrop" onClick$={props.onClose$}>
      <div
        class="dialog"
        role="dialog"
        aria-label={`Error log for ${props.isoName}`}
        onClick$={(e) => e.stopPropagation()}
      >
        <div class="dialog-header">
          <h3>Conversion Error Log</h3>
          <button
            type="button"
            class="dialog-close"
            onClick$={props.onClose$}
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <div class="dialog-body">
          <p class="dialog-iso-name">
            <strong>{props.isoName}</strong>
          </p>
          {loading.value ? (
            <p class="quiet-copy">Loading log…</p>
          ) : error.value ? (
            <p class="message error" role="alert">{error.value}</p>
          ) : (
            <pre class="log-content">{log.value}</pre>
          )}
        </div>
      </div>
    </div>
  );
});

const ConversionsView = component$<{ initial?: ConversionEnvelope }>(
  (props) => {
    const conv = useStore<{
      conversions?: ConversionEnvelope;
      inbox?: ConversionInbox;
      error: string;
    }>({ conversions: props.initial, inbox: undefined, error: "" });
    const logDialog = useSignal<string>("");

    useTask$(({ cleanup }) => {
      let stopped = false;
      const load = async () => {
        try {
          const [conversions, inbox] = await Promise.all([
            api<ConversionEnvelope>("/conversions"),
            api<ConversionInbox>("/conversions/inbox"),
          ]);
          if (stopped) return;
          conv.conversions = conversions;
          conv.inbox = inbox;
          conv.error = "";
        } catch (error) {
          if (!stopped) conv.error = readableError(error);
        }
      };
      void load();
      const timer = setInterval(load, 5000);
      cleanup(() => {
        stopped = true;
        clearInterval(timer);
      });
    });

    const activeConversions =
      conv.conversions?.progress.conversions ?? [];
    const progressQueued = conv.conversions?.progress.queued ?? [];
    const working = activeConversions.length > 0;
    const inboxReady = conv.inbox?.available ?? false;
    const statusLabel = working ? "Working" : "Idle";

    const inboxPending = conv.inbox?.pending ?? [];
    const inboxProcessed = conv.inbox?.processed ?? [];
    const inboxFailed = conv.inbox?.failed ?? [];
    const filesBaseUrl = conv.inbox?.filesBaseUrl ?? "";

    const pendingMap = new Map<string, InboxIso>();
    for (const iso of inboxPending) {
      pendingMap.set(iso.name.replace(/\.iso$/i, ""), iso);
      pendingMap.set(iso.name, iso);
    }

    const queuedEntries: QueuedConversion[] = [];
    const seen = new Set<string>();
    for (const stem of progressQueued) {
      if (seen.has(stem)) continue;
      const cleanStem = stem.replace(/\.iso$/i, "");
      const match = pendingMap.get(stem) ?? pendingMap.get(cleanStem);
      if (match) {
        seen.add(stem);
        seen.add(cleanStem);
        seen.add(match.name);
        seen.add(match.name.replace(/\.iso$/i, ""));
        queuedEntries.push({
          title: match.volumeId || cleanStem,
          isoName: match.name,
        });
      } else {
        seen.add(stem);
        queuedEntries.push({
          title: cleanStem,
          isoName: cleanStem + ".iso",
        });
      }
    }
    for (const iso of inboxPending) {
      const stem = iso.name.replace(/\.iso$/i, "");
      if (!seen.has(stem) && !seen.has(iso.name)) {
        seen.add(stem);
        queuedEntries.push({
          title: iso.volumeId || stem,
          isoName: iso.name,
        });
      }
    }

    const dvdLink = filesBaseUrl
      ? `${filesBaseUrl}/files/_Shared/_ISO/_DVDs/`
      : "";

    return (
      <section class="conversions-layout">
        {logDialog.value && (
          <LogDialog
            isoName={logDialog.value}
            onClose$={() => (logDialog.value = "")}
          />
        )}
        {conv.error && (
          <div class="message error conv-error" role="alert">
            <Icon name="alert" size={18} />
            <span>{conv.error}</span>
            <button type="button" onClick$={() => (conv.error = "")}>
              ×
            </button>
          </div>
        )}
        <div class="conv-main">
          <section class="panel">
            <div class="panel-heading">
              <div>
                <h3>DVD ISO converter</h3>
              </div>
              <span
                class={{
                  "status-badge": true,
                  live: working,
                }}
              >
                {statusLabel}
              </span>
            </div>
            <div class="setup-body">
              {inboxReady ? (
                <p class="setup-ready">
                  The converter is watching{" "}
                  {dvdLink ? (
                    <a
                      href={dvdLink}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      the shared inbox
                    </a>
                  ) : (
                    "the shared inbox"
                  )}
                  .
                  {working
                    ? " An ISO is being converted right now."
                    : " Drop an ISO in the inbox to start a conversion."}
                </p>
              ) : (
                <p class="setup-missing">
                  No ISO files are queued for conversion at the moment. Copy a
                  DVD ISO into the shared inbox at _Shared/_ISO/_DVDs to start a
                  conversion.
                </p>
              )}
              <ol class="setup-steps">
                <li>
                  Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.
                </li>
                <li>
                  Leave the ISO untouched for about one minute so the server
                  picks it up.
                </li>
                <li>
                  Finished films appear in the shared video library. Source ISOs
                  move to _Processed, or to _Failed after repeated failures.
                </li>
                <li>
                  ISO files in the queue can be safely renamed or moved, but do
                  not modify any file that is actively being converted.
                </li>
              </ol>
            </div>
          </section>
          <section class="panel">
            <div class="panel-heading">
              <div>
                <h3>Active conversions</h3>
              </div>
              <span class={{ "status-badge": true, live: working }}>
                {working ? "Working" : "Idle"}
              </span>
            </div>
            <ConversionList
              conversion={activeConversions[0] ?? ({} as Conversion)}
              queuedEntry={queuedEntries}
              expanded
            />
          </section>
        </div>
        <aside class="conv-sidebar">
          <ProcessedCard
            isos={inboxProcessed}
            filesBaseUrl={filesBaseUrl}
          />
          <FailedCard
            isos={inboxFailed}
            onShowLog$={(name) => (logDialog.value = name)}
          />
        </aside>
      </section>
    );
  },
);

const ProcessedCard = component$<{
  isos: InboxIso[];
  filesBaseUrl: string;
}>((props) => (
  <section class="panel side-panel">
    <div class="panel-heading">
      <div>
        <h3>Processed</h3>
        <small>Successfully converted ISOs</small>
      </div>
    </div>
    <div class="side-panel-body">
      {props.isos.length === 0 ? (
        <p class="quiet-copy">Nothing has been processed yet.</p>
      ) : (
        <ul class="side-list">
          {props.isos.map((iso) => (
            <li key={iso.name}>
              <span class="side-item-name">
                <strong>{iso.volumeId || iso.name}</strong>
                <small>{iso.name}</small>
              </span>
              {iso.outputDir && props.filesBaseUrl ? (
                <a
                  class="side-item-link"
                  href={`${props.filesBaseUrl}/files/_Shared/${iso.outputDir}`}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <Icon name="folder" size={12} />&ensp;Open output
                </a>
              ) : iso.outputDir ? (
                <span class="side-item-path">
                  <Icon name="folder" size={12} />&ensp;
                  {iso.outputDir}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  </section>
));

const FailedCard = component$<{
  isos: InboxIso[];
  onShowLog$: QRL<(name: string) => void>;
}>((props) => (
  <section class="panel side-panel">
    <div class="panel-heading">
      <div>
        <h3>Failed</h3>
        <small>ISOs that could not be converted</small>
      </div>
    </div>
    <div class="side-panel-body">
      {props.isos.length === 0 ? (
        <p class="quiet-copy">No failed conversions.</p>
      ) : (
        <ul class="side-list">
          {props.isos.map((iso) => (
            <li key={iso.name}>
              <span class="side-item-name">
                <strong>{iso.volumeId || iso.name}</strong>
                <small>{iso.name}</small>
              </span>
              {iso.hasErrorLog && (
                <button
                  type="button"
                  class="side-item-log-btn"
                  onClick$={() => props.onShowLog$(iso.name)}
                >
                  Show log
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  </section>
));

function formatModified(modifiedNs: number): string {
  if (!Number.isFinite(modifiedNs) || modifiedNs <= 0) return "—";
  return new Date(modifiedNs / 1e6).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

interface SubtitleMatch {
  providerId: string;
  fileId: number;
  fileName: string;
  language: string;
  release: string;
  downloadCount: number;
  fps?: number;
  votes?: number;
  uploadDate?: string;
  subFormat?: string;
  hearingImpaired: boolean;
  hashMatched: boolean;
  machineTranslated: boolean;
  aiTranslated: boolean;
  fpsCompatible?: boolean | null;
}

interface SubtitleCue {
  index: number;
  startMs: number;
  endMs: number;
  text: string;
}

interface SubtitleContent {
  provider: string;
  fileId: number;
  cues: SubtitleCue[];
  truncated: boolean;
  requestId: string;
}

type MusicLookupMode = "auto" | "fingerprint" | "search";

interface MusicCandidate {
  releaseGroupId: string;
  artist: string;
  title: string;
  releaseType?: string;
  year?: number;
  genres: string[];
  label?: string;
  trackCount?: number;
  matchMethod: "fingerprint" | "search";
}

interface SubtitleState {
  rootId: string;
  items: CatalogItem[];
  itemId: string;
  language: string;
  query: string;
  hearingImpaired: boolean;
  showWithSubtitles: boolean;
  subtitleStatus: Record<string, "none" | "sidecar" | "embedded" | "both">;
  loadingItems: boolean;
  searching: boolean;
  installing: boolean;
  confirming: boolean;
  loadingContent: boolean;
  results: SubtitleMatch[];
  video?: VideoProbe | null;
  content?: SubtitleContent;
  contentError: string;
  preview?: MutationPreview;
  error: string;
  notice: string;
}

type SubtitleStatus = "none" | "sidecar" | "embedded" | "both";

function subtitleStatusMap(
  items: CatalogItem[],
): Record<string, SubtitleStatus> {
  const statuses: Record<string, SubtitleStatus> = {};
  const subtitleItems = items.filter((item) => item.mediaKind === "subtitle");
  for (const item of items) {
    if (item.mediaKind !== "video") continue;
    const videoPath = item.relativePath;
    const videoStem = videoPath.replace(/\.[^/.]+$/, "");
    const hasSidecar = subtitleItems.some((subtitle) => {
      const subtitleStem = subtitle.relativePath.replace(/\.[^/.]+$/, "");
      return (
        subtitleStem === videoStem ||
        subtitleStem.startsWith(`${videoStem}.`) ||
        videoStem.startsWith(`${subtitleStem}.`)
      );
    });
    const hasEmbedded = item.videoProbe?.hasEmbeddedSubtitles === true;
    statuses[videoPath] =
      hasSidecar && hasEmbedded
        ? "both"
        : hasSidecar
          ? "sidecar"
          : hasEmbedded
            ? "embedded"
            : "none";
  }
  return statuses;
}

function subtitleStatusLabel(status: SubtitleStatus | undefined): string {
  switch (status) {
    case "sidecar":
      return " (has subtitles)";
    case "embedded":
      return " (embedded subtitles)";
    case "both":
      return " (subtitles + embedded)";
    default:
      return "";
  }
}

function formatCueTime(milliseconds: number): string {
  const total = Math.max(0, Math.floor(milliseconds));
  const hours = Math.floor(total / 3_600_000);
  const minutes = Math.floor((total % 3_600_000) / 60_000);
  const seconds = Math.floor((total % 60_000) / 1_000);
  const millis = total % 1_000;
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(hours)}:${pad(minutes)}:${pad(seconds)},${pad(millis, 3)}`;
}

const SubtitleView = component$<{
  roots: MediaRoot[];
  session?: Session;
  status?: Status;
}>((props) => {
  const uploadInput = useSignal<HTMLInputElement>();
  const videoRoots = props.roots.filter((root) => root.category === "videos");
  const providerAvailable =
    props.status?.integrations.some(
      (integration) =>
        integration.id === "opensubtitles" && integration.available,
    ) ?? false;
  const subtitle = useStore<SubtitleState>({
    rootId: videoRoots[0]?.id ?? "",
    items: [],
    itemId: "",
    language: "en",
    query: "",
    hearingImpaired: false,
    showWithSubtitles: false,
    subtitleStatus: {},
    loadingItems: false,
    searching: false,
    installing: false,
    confirming: false,
    loadingContent: false,
    results: [],
    video: undefined,
    contentError: "",
    error: "",
    notice: "",
  });

  const loadVideos = $(async (rootId: string) => {
    subtitle.rootId = rootId;
    subtitle.loadingItems = true;
    subtitle.itemId = "";
    subtitle.results = [];
    subtitle.video = undefined;
    subtitle.content = undefined;
    subtitle.error = "";
    try {
      let items: CatalogItem[] = [];
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const result = await api<{
          items: CatalogItem[];
          probePending: boolean;
        }>(
          `/items?rootId=${encodeURIComponent(rootId)}&includeVideoProbes=true`,
        );
        items = result.items;
        if (!result.probePending) break;
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      subtitle.items = items;
      subtitle.subtitleStatus = subtitleStatusMap(items);
      const firstVideo = items.find(
        (item) =>
          item.mediaKind === "video" &&
          subtitle.subtitleStatus[item.relativePath] === "none",
      );
      subtitle.itemId = firstVideo?.id ?? "";
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.loadingItems = false;
    }
  });

  useVisibleTask$(async () => {
    if (subtitle.rootId) await loadVideos(subtitle.rootId);
  });

  const search = $(async () => {
    if (!subtitle.itemId || subtitle.searching) return;
    subtitle.searching = true;
    subtitle.error = "";
    subtitle.notice = "";
    subtitle.preview = undefined;
    subtitle.content = undefined;
    subtitle.video = undefined;
    try {
      const parameters = new URLSearchParams({ languages: subtitle.language });
      if (subtitle.query.trim()) parameters.set("query", subtitle.query.trim());
      const response = await api<{
        matchMethod: "movie-hash" | "title-fallback";
        results: SubtitleMatch[];
        video?: VideoProbe | null;
      }>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/search?${parameters}`,
      );
      subtitle.results = response.results;
      subtitle.video = response.video ?? null;
      if (response.results.length === 0) {
        subtitle.notice =
          "OpenSubtitles returned no matches for this title and language.";
      } else if (response.matchMethod === "movie-hash") {
        subtitle.notice =
          "These subtitles are exact file-hash matches and are the best candidates for synchronized timing.";
      } else {
        subtitle.notice =
          "No exact file-hash match was found, so these are title-based candidates. Check the release name before previewing.";
      }
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.searching = false;
    }
  });

  const viewContent = $(async (match: SubtitleMatch) => {
    if (!subtitle.itemId || subtitle.loadingContent) return;
    subtitle.loadingContent = true;
    subtitle.contentError = "";
    try {
      subtitle.content = await api<SubtitleContent>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/provider/${match.fileId}/content`,
      );
    } catch (error) {
      subtitle.contentError = readableError(error);
    } finally {
      subtitle.loadingContent = false;
    }
  });

  const selectProviderSubtitle = $(async (match: SubtitleMatch) => {
    if (!subtitle.itemId || subtitle.installing) return;
    subtitle.installing = true;
    subtitle.error = "";
    subtitle.notice = "";
    try {
      subtitle.preview = await api<MutationPreview>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/provider`,
        {
          method: "POST",
          body: JSON.stringify({
            fileId: match.fileId,
            language: match.language || subtitle.language,
            hearingImpaired: subtitle.hearingImpaired || match.hearingImpaired,
          }),
        },
      );
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.installing = false;
    }
  });

  const confirmInstall = $(async () => {
    if (!subtitle.preview || subtitle.confirming) return;
    subtitle.confirming = true;
    subtitle.error = "";
    try {
      await api(`/plans/${encodeURIComponent(subtitle.preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${subtitle.preview.digest}"` },
      });
      subtitle.notice =
        "The subtitle install was added to the global mutation queue.";
      subtitle.preview = undefined;
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.confirming = false;
    }
  });

  const videoItems = subtitle.items.filter(
    (item) => item.mediaKind === "video",
  );
  const selectableVideos = subtitle.showWithSubtitles
    ? videoItems
    : videoItems.filter(
        (item) => subtitle.subtitleStatus[item.relativePath] === "none",
      );

  return (
    <section class="subtitle-layout">
      {subtitle.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{subtitle.error}</span>
          <button type="button" onClick$={() => (subtitle.error = "")}>
            ×
          </button>
        </div>
      )}
      {subtitle.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{subtitle.notice}</span>
        </div>
      )}

      <section class="panel subtitle-controls">
        <div class="panel-heading">
          <div>
            <h3>Catalog selection</h3>
          </div>
          <span class={{ "status-badge": true, live: props.session?.canEdit }}>
            {props.session?.canEdit ? "Editor" : "Viewer"}
          </span>
        </div>
        <div class="subtitle-fields">
          <label>
            <span>Video library</span>
            <select
              value={subtitle.rootId}
              onChange$={(_, select) => loadVideos(select.value)}
            >
              {videoRoots.map((root) => (
                <option value={root.id} key={root.id}>
                  {`${root.label}${root.available ? "" : " (unavailable)"}`}
                </option>
              ))}
            </select>
          </label>
          <label class="video-select">
            <span>Cataloged video</span>
            <select
              value={subtitle.itemId}
              disabled={subtitle.loadingItems || videoItems.length === 0}
              onChange$={(_, select) => {
                subtitle.itemId = select.value;
                subtitle.results = [];
                subtitle.video = undefined;
                subtitle.preview = undefined;
                subtitle.content = undefined;
              }}
            >
              <option value="">
                {subtitle.loadingItems
                  ? "Loading videos…"
                  : videoItems.length === 0
                    ? "No supported videos found in this library"
                    : selectableVideos.length === 0
                      ? "No videos without subtitles in this library"
                      : "Choose a video…"}
              </option>
              {selectableVideos.map((item) => (
                <option value={item.id} key={item.id}>
                  {`${item.relativePath}${subtitleStatusLabel(
                    subtitle.subtitleStatus[item.relativePath],
                  )}`}
                </option>
              ))}
            </select>
          </label>
          <label class="language-field">
            <span>Language</span>
            <input
              value={subtitle.language}
              maxLength={15}
              placeholder="en"
              onInput$={(_, input) =>
                (subtitle.language = input.value
                  .toLowerCase()
                  .replace(/[^a-z0-9-]/g, "")
                  .slice(0, 15))
              }
            />
          </label>
          <label class="checkbox-field">
            <input
              type="checkbox"
              checked={subtitle.hearingImpaired}
              onChange$={(_, input) =>
                (subtitle.hearingImpaired = input.checked)
              }
            />
            <span>Prefer SDH / hearing-impaired naming</span>
          </label>
          <label class="checkbox-field">
            <input
              type="checkbox"
              checked={subtitle.showWithSubtitles}
              onChange$={(_, input) =>
                (subtitle.showWithSubtitles = input.checked)
              }
            />
            <span>Show files that already have subtitles</span>
          </label>
        </div>
      </section>

      <div class="subtitle-workflows">
        <section class="panel provider-panel">
          <div class="panel-heading">
            <div>
              <h3>OpenSubtitles</h3>
            </div>
            <span class={{ "status-badge": true, live: providerAvailable }}>
              {providerAvailable ? "Configured" : "Not configured"}
            </span>
          </div>
          <div class="setup-body">
            {providerAvailable ? (
              <p class="setup-ready">
                Online search is set up and working. Choose a cataloged video
                above, then search: the file hash is checked first for exact
                matches, with a title fallback.
              </p>
            ) : (
              <>
                <p class="setup-missing">
                  Online search is not set up on this server. Subtitle uploads
                  on the right work without it. To enable search:
                </p>
                <ol class="setup-steps">
                  <li>
                    Create an account at
                    <a
                      class="text-button"
                      href="https://www.opensubtitles.com/en/signup"
                      target="_blank"
                      rel="noreferrer"
                    >
                      opensubtitles.com
                    </a>
                    .
                  </li>
                  <li>
                    Log in and create an application API key at
                    <a
                      class="text-button"
                      href="https://www.opensubtitles.com/consumers"
                      target="_blank"
                      rel="noreferrer"
                    >
                      opensubtitles.com/consumers
                    </a>
                    , selecting "OpenSubtitles REST API" as the API and noting
                    your account username and password.
                  </li>
                  <li>
                    Add those credentials to the server's encrypted
                    openSubtitlesCredentials secret.
                  </li>
                  <li>
                    Rebuild the server. The "Configured" indicator appears here
                    once search is live.
                  </li>
                </ol>
              </>
            )}
          </div>
          <div class="provider-search">
            <label>
              <span>
                Search title <small>optional override</small>
              </span>
              <input
                value={subtitle.query}
                maxLength={200}
                placeholder="Only used if the file hash has no match"
                onInput$={(_, input) => (subtitle.query = input.value)}
              />
            </label>
            <button
              class="primary-button"
              type="button"
              disabled={
                !providerAvailable ||
                !props.session?.canEdit ||
                !subtitle.itemId ||
                !subtitle.language ||
                subtitle.searching
              }
              onClick$={search}
            >
              <Icon name="scan" size={18} />
              {subtitle.searching ? "Searching…" : "Search matches"}
            </button>
          </div>
          <div class="subtitle-results">
            {subtitle.video && (
              <p class="video-summary">
                <strong>Video:</strong>{" "}
                {subtitle.video.codec ?? "unknown codec"}
                {subtitle.video.width && subtitle.video.height
                  ? ` · ${subtitle.video.width}×${subtitle.video.height}`
                  : ""}
                {subtitle.video.fps
                  ? ` · ${subtitle.video.fps.toFixed(3)} fps`
                  : ""}
                {subtitle.video.hasEmbeddedSubtitles
                  ? ` · ${
                      subtitle.video.subtitleLanguages?.length > 0
                        ? subtitle.video.subtitleLanguages.join(", ")
                        : "embedded"
                    } subtitle stream`
                  : ""}
              </p>
            )}
            {subtitle.results.map((match) => (
              <article
                class="subtitle-result"
                key={`${match.providerId}-${match.fileId}`}
              >
                <div>
                  <strong>{match.release || match.fileName}</strong>
                  <span>
                    {match.language} · {match.downloadCount.toLocaleString()}{" "}
                    downloads
                    {match.fps ? ` · ${match.fps.toFixed(3)} fps` : ""}
                    {match.fpsCompatible === false
                      ? " · fps mismatch"
                      : match.fpsCompatible === true
                        ? " · fps matches video"
                        : ""}
                    {match.subFormat ? ` · ${match.subFormat}` : ""}
                    {match.hashMatched ? " · exact file match" : ""}
                    {match.hearingImpaired ? " · SDH" : ""}
                    {match.machineTranslated || match.aiTranslated
                      ? " · machine translated"
                      : ""}
                    {match.votes ? ` · ${match.votes} votes` : ""}
                    {match.uploadDate
                      ? ` · ${new Date(match.uploadDate).toLocaleDateString()}`
                      : ""}
                  </span>
                </div>
                <div class="subtitle-result-actions">
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={subtitle.installing}
                    onClick$={() => selectProviderSubtitle(match)}
                  >
                    Install
                  </button>
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={subtitle.loadingContent}
                    onClick$={() => viewContent(match)}
                  >
                    {subtitle.loadingContent ? "Loading…" : "View content"}
                  </button>
                </div>
              </article>
            ))}
            {subtitle.results.length === 0 && (
              <p class="quiet-copy">
                Search results will show release names, language, accessibility,
                translation flags, and frame rate so an editor can choose the
                closest match.
              </p>
            )}
          </div>
          {subtitle.contentError && (
            <p class="quiet-copy content-error" role="alert">
              {subtitle.contentError}
            </p>
          )}
          {subtitle.content && (
            <section class="subtitle-content">
              <div class="panel-heading">
                <div>
                  <h4>Content preview</h4>
                </div>
                <button
                  class="close-button"
                  type="button"
                  aria-label="Close subtitle content preview"
                  onClick$={() => (subtitle.content = undefined)}
                >
                  ×
                </button>
              </div>
              <ol class="subtitle-cue-list">
                {subtitle.content.cues.map((cue) => (
                  <li class="subtitle-cue" key={cue.index}>
                    <time>
                      {formatCueTime(cue.startMs)} → {formatCueTime(cue.endMs)}
                    </time>
                    <span>{cue.text || "—"}</span>
                  </li>
                ))}
              </ol>
              {subtitle.content.truncated && (
                <p class="quiet-copy">
                  Only the first 40 cues are shown for this preview.
                </p>
              )}
            </section>
          )}
        </section>

        <section class="panel upload-panel">
          <div class="panel-heading">
            <div>
              <h3>Upload subtitle</h3>
            </div>
          </div>
          <div class="upload-copy">
            <div class="workflow-icon small">
              <Icon name="captions" size={24} />
            </div>
            <h4>SRT, WebVTT, or ASS</h4>
            <p>
              Files must be UTF-8 text and no larger than 10 MiB. The video is
              never remuxed or re-encoded.
            </p>
            <input
              ref={uploadInput}
              class="visually-hidden"
              type="file"
              accept=".srt,.vtt,.ass,application/x-subrip,text/vtt"
              onChange$={async (_, input) => {
                const file = input.files?.[0];
                if (!file || !subtitle.itemId || subtitle.installing) return;
                const format = file.name.split(".").at(-1)?.toLowerCase() ?? "";
                subtitle.installing = true;
                subtitle.error = "";
                subtitle.notice = "";
                try {
                  const parameters = new URLSearchParams({
                    language: subtitle.language,
                    format,
                    hearingImpaired: String(subtitle.hearingImpaired),
                  });
                  subtitle.preview = await api<MutationPreview>(
                    `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/upload?${parameters}`,
                    {
                      method: "POST",
                      headers: { "content-type": file.type || "text/plain" },
                      body: file,
                    },
                  );
                } catch (error) {
                  subtitle.error = readableError(error);
                } finally {
                  subtitle.installing = false;
                  input.value = "";
                }
              }}
            />
            <button
              class="secondary-button"
              type="button"
              disabled={
                !props.session?.canEdit ||
                !subtitle.itemId ||
                !subtitle.language ||
                subtitle.installing
              }
              onClick$={() => uploadInput.value?.click()}
            >
              <Icon name="folder" size={18} />
              {subtitle.installing ? "Preparing…" : "Choose subtitle file"}
            </button>
          </div>
        </section>
      </div>

      {subtitle.preview && (
        <section class="panel subtitle-preview">
          <div class="panel-heading">
            <div>
              <h3>Confirm sidecar destination</h3>
            </div>
            <button
              class="close-button"
              type="button"
              aria-label="Discard subtitle preview"
              onClick$={() => (subtitle.preview = undefined)}
            >
              ×
            </button>
          </div>
          <div class="subtitle-preview-body">
            <div class="destination-card">
              <Icon name="captions" size={21} />
              <span>
                <small>New sidecar</small>
                <strong>
                  {subtitle.preview.actions[0]?.destinationRelativePath}
                </strong>
              </span>
            </div>
            {subtitle.preview.warnings.map((warning) => (
              <p class="plan-warning" key={warning}>
                <Icon name="shield" size={16} /> {warning}
              </p>
            ))}
            <div class="plan-actions">
              <span>
                This preview expires in 30 minutes. The broker verifies the
                staged file and refuses to replace an existing subtitle.
              </span>
              <button
                class="primary-button"
                type="button"
                disabled={
                  props.status?.mutationMode !== "enabled" ||
                  subtitle.confirming
                }
                onClick$={confirmInstall}
              >
                <Icon name="check" size={18} />
                {subtitle.confirming ? "Queuing…" : "Confirm exact install"}
              </button>
            </div>
          </div>
        </section>
      )}
    </section>
  );
});

type EditorTab = "metadata" | "rename" | "subtitles";

type MetadataSection = "basics" | "people" | "advanced";

const METADATA_SECTIONS: Array<{ id: MetadataSection; label: string }> = [
  { id: "basics", label: "Basics" },
  { id: "people", label: "People" },
  { id: "advanced", label: "Advanced" },
];

interface MetadataEditorState {
  itemId: string;
  mediaType: string;
  title: string;
  year: string;
  authors: string;
  narrators: string;
  series: string;
  volumeNumber: string;
  publisher: string;
  isbn: string;
  language: string;
  genres: string;
  description: string;
  season: string;
  episode: string;
  episodeTitle: string;
  premiereDate: string;
  runtimeMinutes: string;
  officialRating: string;
  communityRating: string;
  writers: string;
  providerIds: Record<string, string>;
  videoStreams: Array<Record<string, unknown>>;
  audioStreams: Array<Record<string, unknown>>;
  sources: string[];
  lookupMode: MusicLookupMode;
  lookupArtist: string;
  lookupTitle: string;
  candidates: MusicCandidate[];
  lookupLoading: boolean;
  lookupError: string;
  loadingDetails: boolean;
  planning: boolean;
  confirming: boolean;
  previewSelectionKey: string;
  preview?: MutationPreview;
}

const ItemEditor = component$<{
  state: DashboardState;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
  folder?: {
    rootId: string;
    relativePath: string;
  };
  close$?: QRL<() => void>;
}>((props) => {
  const tab = useSignal<EditorTab>("metadata");
  const section = useSignal<MetadataSection>("basics");
  const selectedItem = props.state.items.find(
    (item) => item.id === props.state.selectedItemId,
  );
  const selectedRoot = props.state.roots.find(
    (root) => root.id === (props.folder?.rootId ?? selectedItem?.rootId),
  );
  const musicbrainzIntegration = props.state.status?.integrations.find(
    (integration) => integration.id === "musicbrainz",
  );
  const musicbrainzAvailable = musicbrainzIntegration?.available ?? false;
  const fingerprintAvailable =
    musicbrainzIntegration?.capabilities.includes("musicbrainz-fingerprint") ??
    false;
  const metadata = useStore<MetadataEditorState>({
    itemId: "",
    mediaType: "movie",
    title: "",
    year: "",
    authors: "",
    narrators: "",
    series: "",
    volumeNumber: "",
    publisher: "",
    isbn: "",
    language: "en",
    genres: "",
    description: "",
    season: "",
    episode: "",
    episodeTitle: "",
    premiereDate: "",
    runtimeMinutes: "",
    officialRating: "",
    communityRating: "",
    writers: "",
    providerIds: {},
    videoStreams: [],
    audioStreams: [],
    sources: [],
    lookupMode: "auto",
    lookupArtist: "",
    lookupTitle: "",
    candidates: [],
    lookupLoading: false,
    lookupError: "",
    loadingDetails: false,
    planning: false,
    confirming: false,
    previewSelectionKey: "",
  });

  const closeEditor = $(() => {
    if (props.folder) {
      props.close$?.();
      return;
    }
    props.state.selectedItemId = "";
    props.state.preview = undefined;
    props.state.notice = "";
  });

  useTask$(async ({ track }) => {
    const selectionKey = track(() =>
      props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId,
    );
    if (!selectionKey) return;
    tab.value = "metadata";
    section.value = "basics";
    const item = props.folder
      ? undefined
      : props.state.items.find(
          (candidate) => candidate.id === props.state.selectedItemId,
        );
    metadata.itemId = selectionKey;
    metadata.planning = false;
    metadata.confirming = false;
    metadata.previewSelectionKey = "";
    metadata.preview = undefined;
    metadata.loadingDetails = true;
    metadata.mediaType = props.folder
      ? mediaTypeForFolder(selectedRoot?.category, props.folder.relativePath)
      : mediaTypeForItem(item);
    const filename =
      (props.folder?.relativePath ?? item?.relativePath)?.split("/").at(-1) ??
      "";
    const tvEpisode = parseTvEpisodeFilename(filename);
    metadata.title =
      tvEpisode?.title ??
      filename.replace(/\.[^.]+$/, "").replace(/ \([0-9]{4}\)$/, "");
    metadata.year =
      tvEpisode?.year ?? filename.match(/ \(([0-9]{4})\)$/)?.[1] ?? "";
    metadata.season = tvEpisode?.season ?? "";
    metadata.episode = tvEpisode?.episode ?? "";
    metadata.episodeTitle = tvEpisode?.episodeTitle ?? "";
    metadata.description = "";
    metadata.publisher = "";
    metadata.language = "en";
    metadata.genres = "";
    metadata.writers = "";
    metadata.premiereDate = "";
    metadata.runtimeMinutes = "";
    metadata.officialRating = "";
    metadata.communityRating = "";
    metadata.authors = "";
    metadata.narrators = "";
    metadata.series = "";
    metadata.volumeNumber = "";
    metadata.isbn = "";
    metadata.providerIds = {};
    metadata.videoStreams = [];
    metadata.audioStreams = [];
    metadata.sources = ["filename"];
    metadata.lookupMode = "auto";
    metadata.lookupArtist = "";
    metadata.lookupTitle = "";
    metadata.candidates = [];
    metadata.lookupLoading = false;
    metadata.lookupError = "";
    props.state.error = "";
    try {
      const metadataPath = props.folder
        ? `/folders/metadata?${new URLSearchParams({
            rootId: props.folder.rootId,
            relativePath: props.folder.relativePath,
          })}`
        : `/items/${encodeURIComponent(props.state.selectedItemId)}/metadata`;
      const details = await api<Record<string, unknown>>(metadataPath);
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId !== selectionKey ||
        visibleSelectionKey !== selectionKey
      )
        return;
      if (details.mediaType) metadata.mediaType = String(details.mediaType);
      if (details.title) metadata.title = String(details.title);
      if (details.year != null && details.year !== "")
        metadata.year = String(details.year);
      if (details.series) metadata.series = String(details.series);
      if (details.season != null && details.season !== "")
        metadata.season = String(details.season);
      if (details.episode != null && details.episode !== "")
        metadata.episode = String(details.episode);
      if (details.episodeTitle)
        metadata.episodeTitle = String(details.episodeTitle);
      if (details.description)
        metadata.description = String(details.description);
      if (details.publisher) metadata.publisher = String(details.publisher);
      if (details.language) metadata.language = String(details.language);
      metadata.genres = Array.isArray(details.genres)
        ? (details.genres as string[]).join(", ")
        : metadata.genres;
      metadata.writers = Array.isArray(details.writers)
        ? (details.writers as string[]).join(", ")
        : metadata.writers;
      if (details.premiereDate)
        metadata.premiereDate = String(details.premiereDate).slice(0, 10);
      if (details.runtimeMinutes != null && details.runtimeMinutes !== "")
        metadata.runtimeMinutes = String(details.runtimeMinutes);
      if (details.officialRating)
        metadata.officialRating = String(details.officialRating);
      if (details.communityRating != null && details.communityRating !== "")
        metadata.communityRating = String(details.communityRating);
      metadata.providerIds =
        (details.providerIds as Record<string, string>) ?? {};
      metadata.videoStreams =
        (details.videoStreams as Array<Record<string, unknown>>) ?? [];
      metadata.audioStreams =
        (details.audioStreams as Array<Record<string, unknown>>) ?? [];
      metadata.sources = (details.sources as string[]) ?? ["filename"];
      metadata.lookupArtist = metadata.authors;
      metadata.lookupTitle = metadata.title;
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        metadata.loadingDetails = false;
    }
  });

  const previewMetadata = $(async () => {
    if (!metadata.itemId || !metadata.title.trim() || metadata.planning) return;
    const selectionKey = metadata.itemId;
    metadata.planning = true;
    props.state.error = "";
    props.state.notice = "";
    const fields: Record<string, unknown> = {
      mediaType: metadata.mediaType,
      title: metadata.title.trim(),
      authors: commaSeparated(metadata.authors),
      narrators: commaSeparated(metadata.narrators),
      genres: commaSeparated(metadata.genres),
      writers: commaSeparated(metadata.writers),
      providerIds: metadata.providerIds,
    };
    const optional: Array<[string, string]> = [
      ["series", metadata.series],
      ["volumeNumber", metadata.volumeNumber],
      ["publisher", metadata.publisher],
      ["isbn", metadata.isbn],
      ["language", metadata.language],
      ["description", metadata.description],
      ["episodeTitle", metadata.episodeTitle],
      ["premiereDate", metadata.premiereDate],
      ["officialRating", metadata.officialRating],
    ];
    for (const [key, value] of optional) {
      if (value.trim()) fields[key] = value.trim();
    }
    if (metadata.year.trim()) fields.year = Number.parseInt(metadata.year, 10);
    if (metadata.season.trim())
      fields.season = Number.parseInt(metadata.season, 10);
    if (metadata.episode.trim())
      fields.episode = Number.parseInt(metadata.episode, 10);
    if (metadata.runtimeMinutes.trim())
      fields.runtimeMinutes = Number.parseInt(metadata.runtimeMinutes, 10);
    if (metadata.communityRating.trim())
      fields.communityRating = Number.parseFloat(metadata.communityRating);
    try {
      const sidecarPath = props.folder
        ? `/folders/metadata/sidecar?${new URLSearchParams({
            rootId: props.folder.rootId,
            relativePath: props.folder.relativePath,
          })}`
        : `/items/${encodeURIComponent(props.state.selectedItemId)}/metadata/sidecar`;
      const preview = await api<MutationPreview>(sidecarPath, {
        method: "POST",
        body: JSON.stringify(fields),
      });
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      ) {
        metadata.previewSelectionKey = selectionKey;
        metadata.preview = preview;
      }
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        metadata.planning = false;
    }
  });

  const confirmMetadata = $(async () => {
    if (
      !metadata.preview ||
      metadata.previewSelectionKey !== metadata.itemId ||
      metadata.confirming
    )
      return;
    const selectionKey = metadata.itemId;
    const preview = metadata.preview;
    metadata.confirming = true;
    props.state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${preview.digest}"` },
      });
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId !== selectionKey ||
        visibleSelectionKey !== selectionKey
      )
        return;
      props.state.notice =
        "The metadata sidecar was added to the global mutation queue.";
      metadata.previewSelectionKey = "";
      metadata.preview = undefined;
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        metadata.confirming = false;
    }
  });

  const lookupMusic = $(async () => {
    if (!metadata.itemId || metadata.lookupLoading) return;
    metadata.lookupLoading = true;
    metadata.lookupError = "";
    props.state.error = "";
    props.state.notice = "";
    const body: Record<string, unknown> = { mode: metadata.lookupMode };
    if (metadata.lookupArtist.trim())
      body.artist = metadata.lookupArtist.trim();
    if (metadata.lookupTitle.trim()) body.title = metadata.lookupTitle.trim();
    try {
      const result = await api<{
        requestId: string;
        candidates: MusicCandidate[];
      }>(`/items/${encodeURIComponent(metadata.itemId)}/metadata/lookup`, {
        method: "POST",
        body: JSON.stringify(body),
      });
      metadata.candidates = result.candidates;
      if (result.candidates.length === 0) {
        props.state.notice =
          "MusicBrainz found no matching releases. Try a fingerprint lookup or refine the artist and title.";
      }
    } catch (error) {
      metadata.lookupError = readableError(error);
    } finally {
      metadata.lookupLoading = false;
    }
  });

  const fillMusicCandidate = $((candidate: MusicCandidate) => {
    metadata.title = candidate.title;
    metadata.authors = candidate.artist;
    if (candidate.year) metadata.year = String(candidate.year);
    if (candidate.genres.length > 0)
      metadata.genres = candidate.genres.join(", ");
    if (candidate.label) metadata.publisher = candidate.label;
    props.state.error = "";
    props.state.notice = `Filled the form from “${candidate.title}”. Review the fields before previewing the metadata sidecar.`;
  });

  return (
    <section class="panel editor-card">
      <div class="editor-heading">
        <div class="editor-tabs" role="tablist" aria-label="Edit selected item">
          <button
            type="button"
            role="tab"
            aria-selected={tab.value === "metadata"}
            class={{ "editor-tab": true, active: tab.value === "metadata" }}
            onClick$={() => (tab.value = "metadata")}
          >
            <Icon name="tag" size={16} />
            Metadata
          </button>
          {!props.folder && (
            <>
              <button
                type="button"
                role="tab"
                aria-selected={tab.value === "rename"}
                class={{ "editor-tab": true, active: tab.value === "rename" }}
                onClick$={() => (tab.value = "rename")}
              >
                <Icon name="scan" size={16} />
                Rename
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={tab.value === "subtitles"}
                class={{
                  "editor-tab": true,
                  active: tab.value === "subtitles",
                }}
                onClick$={() => (tab.value = "subtitles")}
              >
                <Icon name="captions" size={16} />
                Subtitles
              </button>
            </>
          )}
        </div>
        <button
          class="close-button"
          type="button"
          aria-label="Close item editor"
          onClick$={closeEditor}
        >
          ×
        </button>
      </div>

      {tab.value === "metadata" ? (
        <>
          {metadata.mediaType === "music" && !props.folder && (
            <section class="panel musicbrainz-panel">
              <div class="panel-heading">
                <div>
                  <h3>MusicBrainz lookup</h3>
                </div>
                <span
                  class={{ "status-badge": true, live: musicbrainzAvailable }}
                >
                  {musicbrainzAvailable
                    ? fingerprintAvailable
                      ? "Fingerprint ready"
                      : "Search only"
                    : "Unavailable"}
                </span>
              </div>
              <p class="quiet-copy">
                Match the album release on MusicBrainz and fill this form from
                it before previewing the sidecar. Fingerprint lookup matches the
                audio itself but needs an AcoustID API key on the server.
              </p>
              <div class="metadata-form">
                <label>
                  <span>Lookup mode</span>
                  <select
                    value={metadata.lookupMode}
                    onChange$={(_, select) =>
                      (metadata.lookupMode = select.value as MusicLookupMode)
                    }
                  >
                    <option value="auto">
                      Auto — fingerprint, then search
                    </option>
                    <option
                      value="fingerprint"
                      disabled={!fingerprintAvailable}
                    >
                      Fingerprint — match the audio
                    </option>
                    <option value="search">Search — artist and title</option>
                  </select>
                </label>
                <label>
                  <span>Artist</span>
                  <input
                    value={metadata.lookupArtist}
                    maxLength={500}
                    placeholder="e.g. Nirvana"
                    onInput$={(_, input) =>
                      (metadata.lookupArtist = input.value)
                    }
                  />
                </label>
                <label class="title-input">
                  <span>Title</span>
                  <input
                    value={metadata.lookupTitle}
                    maxLength={500}
                    placeholder="e.g. Nevermind"
                    onInput$={(_, input) =>
                      (metadata.lookupTitle = input.value)
                    }
                  />
                </label>
                <div class="metadata-actions">
                  <button
                    class="primary-button"
                    type="button"
                    disabled={
                      !musicbrainzAvailable ||
                      !props.state.session?.canEdit ||
                      !metadata.itemId ||
                      metadata.lookupLoading ||
                      (metadata.lookupMode === "fingerprint" &&
                        !fingerprintAvailable)
                    }
                    onClick$={lookupMusic}
                  >
                    <Icon name="disc" size={18} />
                    {metadata.lookupLoading ? "Looking up…" : "Look up release"}
                  </button>
                </div>
              </div>
              {metadata.lookupError && (
                <p class="error-copy">{metadata.lookupError}</p>
              )}
              <div class="subtitle-results">
                {metadata.candidates.map((candidate) => (
                  <article
                    class="subtitle-result"
                    key={candidate.releaseGroupId}
                  >
                    <div>
                      <strong>
                        {candidate.artist} — {candidate.title}
                      </strong>
                      <span>
                        {candidate.releaseType ?? "Release"} ·{" "}
                        {candidate.year ?? "unknown year"}
                        {candidate.label ? ` · ${candidate.label}` : ""}
                        {candidate.trackCount
                          ? ` · ${candidate.trackCount} tracks`
                          : ""}
                        {candidate.genres.length > 0
                          ? ` · ${candidate.genres.join(", ")}`
                          : ""}
                        {candidate.matchMethod === "fingerprint"
                          ? " · matched by fingerprint"
                          : " · matched by search"}
                      </span>
                    </div>
                    <button
                      class="secondary-button"
                      type="button"
                      onClick$={() => fillMusicCandidate(candidate)}
                    >
                      Fill form
                    </button>
                  </article>
                ))}
                {metadata.candidates.length === 0 && (
                  <p class="quiet-copy">
                    Matched releases will appear here. Fill the form from a
                    release, then preview the metadata sidecar as usual.
                  </p>
                )}
              </div>
            </section>
          )}
          <div
            class="metadata-section-tabs"
            role="tablist"
            aria-label="Metadata fields"
          >
            {METADATA_SECTIONS.map((item) => (
              <button
                type="button"
                role="tab"
                key={item.id}
                aria-selected={section.value === item.id}
                class={{
                  "metadata-section-tab": true,
                  active: section.value === item.id,
                }}
                onClick$={() => (section.value = item.id)}
              >
                {item.label}
              </button>
            ))}
          </div>
          <div class="metadata-form editor-metadata-form">
            {section.value === "basics" && (
              <>
                <label>
                  <span>Media type</span>
                  <select
                    value={metadata.mediaType}
                    disabled={Boolean(props.folder)}
                    onChange$={(_, select) =>
                      (metadata.mediaType = select.value)
                    }
                  >
                    <option value="movie">Movie</option>
                    <option value="collection">Collection</option>
                    <option value="series">TV series</option>
                    <option value="season">TV season</option>
                    <option value="episode">TV episode</option>
                    <option value="music">Music</option>
                    <option value="audiobook">Audiobook</option>
                    <option value="book">Book</option>
                  </select>
                </label>
                <label class="title-input">
                  <span>Title</span>
                  <input
                    value={metadata.title}
                    maxLength={500}
                    onInput$={(_, input) => (metadata.title = input.value)}
                  />
                </label>
                <label>
                  <span>
                    Year <small>omit when unknown</small>
                  </span>
                  <input
                    value={metadata.year}
                    inputMode="numeric"
                    maxLength={4}
                    placeholder="Unknown"
                    onInput$={(_, input) =>
                      (metadata.year = input.value
                        .replace(/\D/g, "")
                        .slice(0, 4))
                    }
                  />
                </label>
                {metadata.mediaType === "episode" && (
                  <>
                    <label>
                      <span>Season</span>
                      <input
                        value={metadata.season}
                        inputMode="numeric"
                        onInput$={(_, input) =>
                          (metadata.season = numericValue(input.value, 4))
                        }
                      />
                    </label>
                    <label>
                      <span>Episode</span>
                      <input
                        value={metadata.episode}
                        inputMode="numeric"
                        onInput$={(_, input) =>
                          (metadata.episode = numericValue(input.value, 5))
                        }
                      />
                    </label>
                    <label class="title-input">
                      <span>Episode title</span>
                      <input
                        value={metadata.episodeTitle}
                        maxLength={500}
                        onInput$={(_, input) =>
                          (metadata.episodeTitle = input.value)
                        }
                      />
                    </label>
                  </>
                )}
                <label>
                  <span>Language code</span>
                  <input
                    value={metadata.language}
                    maxLength={15}
                    onInput$={(_, input) =>
                      (metadata.language = input.value
                        .toLowerCase()
                        .replace(/[^a-z0-9-]/g, ""))
                    }
                  />
                </label>
                <label>
                  <span>
                    Genres <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.genres}
                    onInput$={(_, input) => (metadata.genres = input.value)}
                  />
                </label>
              </>
            )}
            {section.value === "people" && (
              <>
                <label>
                  <span>
                    Authors / artists <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.authors}
                    onInput$={(_, input) => (metadata.authors = input.value)}
                  />
                </label>
                <label>
                  <span>
                    Narrators <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.narrators}
                    onInput$={(_, input) => (metadata.narrators = input.value)}
                  />
                </label>
                <label class="title-input">
                  <span>
                    Writers <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.writers}
                    onInput$={(_, input) => (metadata.writers = input.value)}
                  />
                </label>
                <label>
                  <span>Series</span>
                  <input
                    value={metadata.series}
                    onInput$={(_, input) => (metadata.series = input.value)}
                  />
                </label>
                <label>
                  <span>Volume</span>
                  <input
                    value={metadata.volumeNumber}
                    onInput$={(_, input) =>
                      (metadata.volumeNumber = input.value)
                    }
                  />
                </label>
              </>
            )}
            {section.value === "advanced" && (
              <>
                <label>
                  <span>Publisher / studio</span>
                  <input
                    value={metadata.publisher}
                    onInput$={(_, input) => (metadata.publisher = input.value)}
                  />
                </label>
                <label>
                  <span>Premiere date</span>
                  <input
                    type="date"
                    value={metadata.premiereDate}
                    onInput$={(_, input) =>
                      (metadata.premiereDate = input.value)
                    }
                  />
                </label>
                <label>
                  <span>
                    Runtime <small>minutes</small>
                  </span>
                  <input
                    value={metadata.runtimeMinutes}
                    inputMode="numeric"
                    onInput$={(_, input) =>
                      (metadata.runtimeMinutes = numericValue(input.value, 6))
                    }
                  />
                </label>
                <label>
                  <span>Official rating</span>
                  <input
                    value={metadata.officialRating}
                    maxLength={64}
                    onInput$={(_, input) =>
                      (metadata.officialRating = input.value)
                    }
                  />
                </label>
                <label>
                  <span>
                    Community rating <small>0–10</small>
                  </span>
                  <input
                    value={metadata.communityRating}
                    inputMode="decimal"
                    onInput$={(_, input) =>
                      (metadata.communityRating = input.value
                        .replace(/[^0-9.]/g, "")
                        .slice(0, 5))
                    }
                  />
                </label>
                <label>
                  <span>ISBN</span>
                  <input
                    value={metadata.isbn}
                    onInput$={(_, input) => (metadata.isbn = input.value)}
                  />
                </label>
                <label class="description-input">
                  <span>Description</span>
                  <textarea
                    value={metadata.description}
                    maxLength={20000}
                    rows={5}
                    onInput$={(_, input) =>
                      (metadata.description = input.value)
                    }
                  />
                </label>
              </>
            )}
          </div>
          <div class="metadata-actions">
            <span>
              {metadata.loadingDetails
                ? "Reading available metadata…"
                : `Sources: ${metadata.sources.join(" + ") || "select an item"}. NFO is used for video/music; OPF is used for books and audiobooks.`}
            </span>
            <button
              class="primary-button"
              type="button"
              disabled={
                !props.state.session?.canEdit ||
                !metadata.itemId ||
                metadata.mediaType === "collection" ||
                !metadata.title.trim() ||
                metadata.planning
              }
              onClick$={previewMetadata}
            >
              <Icon name="scan" size={18} />
              {metadata.mediaType === "collection"
                ? "Grouping folder"
                : metadata.planning
                  ? "Preparing…"
                  : "Preview metadata sidecar"}
            </button>
          </div>
          {(metadata.videoStreams.length > 0 ||
            metadata.audioStreams.length > 0 ||
            Object.keys(metadata.providerIds).length > 0) && (
            <div class="editor-facts" aria-label="Jellyfin media facts">
              <h5>Media facts</h5>
              <dl>
                {metadata.videoStreams.map((stream, index) => (
                  <div key={`video-${index}`}>
                    <dt>Video</dt>
                    <dd>
                      {[
                        stream.height ? `${String(stream.height)}p` : "",
                        stream.codec ? String(stream.codec) : "",
                        stream.videoRange ? String(stream.videoRange) : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {metadata.audioStreams.map((stream, index) => (
                  <div key={`audio-${index}`}>
                    <dt>Audio</dt>
                    <dd>
                      {[
                        stream.language ? String(stream.language) : "",
                        stream.codec ? String(stream.codec) : "",
                        stream.channelLayout
                          ? String(stream.channelLayout)
                          : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {Object.entries(metadata.providerIds).map(([provider, id]) => (
                  <div key={provider}>
                    <dt>{provider.toUpperCase()}</dt>
                    <dd>{id}</dd>
                  </div>
                ))}
              </dl>
            </div>
          )}
        </>
      ) : tab.value === "subtitles" ? (
        <SubtitleCard
          items={props.state.items}
          selectedItemId={props.state.selectedItemId}
        />
      ) : (
        <div class="rename-fields">
          <label class="profile-field">
            <span>Media profile</span>
            <select
              value={props.state.editProfile}
              onInput$={(_, input) => {
                props.state.editProfile = input.value as NamingProfile;
                props.state.preview = undefined;
              }}
            >
              {profilesForCategory(selectedRoot?.category).map((profile) => (
                <option value={profile.id} key={profile.id}>
                  {profile.label}
                </option>
              ))}
            </select>
          </label>
          <label class="title-field">
            <span>Title</span>
            <input
              value={props.state.editTitle}
              onInput$={(_, input) => (props.state.editTitle = input.value)}
              autocomplete="off"
            />
          </label>
          <label class="year-field">
            <span>
              Release year <small>optional</small>
            </span>
            <input
              inputMode="numeric"
              maxLength={4}
              placeholder="Unknown"
              value={props.state.editYear}
              onInput$={(_, input) =>
                (props.state.editYear = input.value
                  .replace(/\D/g, "")
                  .slice(0, 4))
              }
            />
          </label>
          {props.state.editProfile === "tv" && (
            <>
              <label class="number-field">
                <span>Season</span>
                <input
                  inputMode="numeric"
                  maxLength={3}
                  placeholder="1"
                  value={props.state.editSeason}
                  onInput$={(_, input) =>
                    (props.state.editSeason = numericValue(input.value, 3))
                  }
                />
              </label>
              <label class="number-field">
                <span>Episode</span>
                <input
                  inputMode="numeric"
                  maxLength={4}
                  placeholder="1"
                  value={props.state.editEpisode}
                  onInput$={(_, input) =>
                    (props.state.editEpisode = numericValue(input.value, 4))
                  }
                />
              </label>
              <label class="detail-field">
                <span>
                  Episode title <small>optional</small>
                </span>
                <input
                  value={props.state.editEpisodeTitle}
                  onInput$={(_, input) =>
                    (props.state.editEpisodeTitle = input.value)
                  }
                  autocomplete="off"
                />
              </label>
            </>
          )}
          {props.state.editProfile === "music" && (
            <>
              <label>
                <span>Artist</span>
                <input
                  value={props.state.editCreator}
                  onInput$={(_, input) =>
                    (props.state.editCreator = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label>
                <span>Album</span>
                <input
                  value={props.state.editCollection}
                  onInput$={(_, input) =>
                    (props.state.editCollection = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label class="number-field">
                <span>Track</span>
                <input
                  inputMode="numeric"
                  maxLength={3}
                  value={props.state.editTrack}
                  onInput$={(_, input) =>
                    (props.state.editTrack = numericValue(input.value, 3))
                  }
                />
              </label>
              <label class="number-field">
                <span>
                  Disc <small>optional</small>
                </span>
                <input
                  inputMode="numeric"
                  maxLength={2}
                  value={props.state.editDisc}
                  onInput$={(_, input) =>
                    (props.state.editDisc = numericValue(input.value, 2))
                  }
                />
              </label>
            </>
          )}
          {["audiobook", "book"].includes(props.state.editProfile) && (
            <>
              <label>
                <span>Author</span>
                <input
                  value={props.state.editCreator}
                  onInput$={(_, input) =>
                    (props.state.editCreator = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label>
                <span>
                  Series <small>optional</small>
                </span>
                <input
                  value={props.state.editCollection}
                  onInput$={(_, input) =>
                    (props.state.editCollection = input.value)
                  }
                  autocomplete="off"
                />
              </label>
            </>
          )}
          <p class="organization-note">
            Folder names are constructed from these fields. Unknown years stay
            omitted; no destination path is accepted from the browser.
          </p>
          <button
            class="secondary-button rename-preview-button"
            type="button"
            disabled={props.state.planning || !renameReady(props.state)}
            onClick$={props.previewRename$}
          >
            <Icon name="scan" size={18} />
            {props.state.planning ? "Preparing…" : "Preview organization"}
          </button>
        </div>
      )}

      {tab.value === "rename"
        ? props.state.preview && (
            <div class="plan-preview">
              <div class="path-change">
                <span>
                  {props.state.preview.actions[0]?.sourceRelativePath}
                </span>
                <Icon name="arrow" size={17} />
                <strong>
                  {props.state.preview.actions[0]?.destinationRelativePath}
                </strong>
              </div>
              {props.state.preview.warnings.map((warning) => (
                <p class="plan-warning" key={warning}>
                  <Icon name="alert" size={16} /> {warning}
                </p>
              ))}
              <div class="plan-actions">
                <span>
                  Preview expires in 30 minutes and is bound to the current file
                  fingerprint.
                </span>
                <button
                  class="primary-button"
                  type="button"
                  disabled={
                    props.state.status?.mutationMode !== "enabled" ||
                    props.state.confirming
                  }
                  onClick$={props.confirmRename$}
                >
                  <Icon name="check" size={18} />
                  {props.state.confirming ? "Queuing…" : "Confirm exact plan"}
                </button>
              </div>
            </div>
          )
        : metadata.preview && (
            <div class="plan-preview">
              <div class="destination-card">
                <Icon name="tag" size={21} />
                <span>
                  <small>Metadata sidecar</small>
                  <strong>
                    {metadata.preview.actions[0]?.destinationRelativePath}
                  </strong>
                </span>
              </div>
              {metadata.preview.warnings.map((warning) => (
                <p class="plan-warning" key={warning}>
                  <Icon name="shield" size={16} /> {warning}
                </p>
              ))}
              <div class="plan-actions">
                <span>
                  Review the destination above. Confirmation installs only the
                  staged sidecar represented by this digest.
                </span>
                <button
                  class="primary-button"
                  type="button"
                  disabled={
                    props.state.status?.mutationMode !== "enabled" ||
                    metadata.confirming
                  }
                  onClick$={confirmMetadata}
                >
                  <Icon name="check" size={18} />
                  {metadata.confirming ? "Queuing…" : "Confirm metadata"}
                </button>
              </div>
            </div>
          )}
    </section>
  );
});

function mediaTypeForItem(item?: CatalogItem): string {
  switch (item?.mediaKind) {
    case "music":
      return "music";
    case "audiobook":
      return "audiobook";
    case "book":
      return "book";
    default:
      return "movie";
  }
}

function mediaTypeForFolder(
  category: string | undefined,
  path: string,
): string {
  switch (category) {
    case "music":
      return "music";
    case "audiobooks":
      return "audiobook";
    case "books":
      return "book";
    case "videos":
      if (path.startsWith("_Shows/")) {
        return /(?:^|\/)Season\s+\d+$/i.test(path) ? "season" : "series";
      }
      return "movie";
    default:
      return "movie";
  }
}

const RefreshView = component$<{ integrations: Integration[] }>((props) => {
  const refresh = useStore<{
    statuses: Record<string, IntegrationRefresh>;
    error: string;
    active: boolean;
  }>({ statuses: {}, error: "", active: true });

  useVisibleTask$(({ cleanup }) => {
    refresh.active = true;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refreshable = props.integrations.filter(
      (integration) =>
        integration.available &&
        integration.capabilities.some((capability) =>
          ["library-refresh", "folder-rescan"].includes(capability),
        ),
    );
    const poll = async () => {
      try {
        const statuses = await Promise.all(
          refreshable.map((integration) =>
            api<IntegrationRefresh>(
              `/integrations/${encodeURIComponent(integration.id)}/refresh`,
            ),
          ),
        );
        if (stopped) return;
        refresh.error = "";
        for (const status of statuses) {
          refresh.statuses[status.integrationId] = status;
        }
        if (
          statuses.some((status) =>
            ["queued", "running"].includes(status.state),
          )
        ) {
          timer = setTimeout(poll, 1000);
        }
      } catch (error) {
        if (!stopped) {
          refresh.error = readableError(error);
          timer = setTimeout(poll, 2000);
        }
      }
    };
    void poll();
    cleanup(() => {
      stopped = true;
      refresh.active = false;
      if (timer) clearTimeout(timer);
    });
  });

  const followRefresh = $(async (integrationId: string) => {
    for (let attempt = 0; attempt < 7200; attempt += 1) {
      await new Promise((resolve) =>
        setTimeout(resolve, attempt === 0 ? 250 : 1000),
      );
      if (!refresh.active) return;
      try {
        const status = await api<IntegrationRefresh>(
          `/integrations/${encodeURIComponent(integrationId)}/refresh`,
        );
        refresh.error = "";
        refresh.statuses[integrationId] = status;
        if (["idle", "succeeded", "failed"].includes(status.state)) return;
      } catch (error) {
        refresh.error = readableError(error);
      }
    }
    if (!refresh.active) return;
    refresh.statuses[integrationId] = {
      integrationId,
      state: "failed",
      message: "Timed out waiting for the refresh adapter to finish.",
    };
  });

  const triggerRefresh = $(async (integration: Integration) => {
    if (refreshPresentation(refresh.statuses[integration.id]).busy) return;
    refresh.error = "";
    try {
      const result = await api<{
        alreadyQueued: boolean;
        requestId: string;
      }>(`/integrations/${encodeURIComponent(integration.id)}/refresh`, {
        method: "POST",
      });
      refresh.statuses[integration.id] = {
        integrationId: integration.id,
        state: "queued",
        requestId: result.requestId,
        message: result.alreadyQueued
          ? "This refresh was already waiting to run."
          : "The refresh request is waiting to run.",
      };
      await followRefresh(integration.id);
    } catch (error) {
      refresh.statuses[integration.id] = {
        integrationId: integration.id,
        state: "failed",
        message: readableError(error),
      };
    }
  });
  const refreshableIntegrations = props.integrations.filter((integration) =>
    integration.capabilities.some((capability) =>
      ["library-refresh", "folder-rescan"].includes(capability),
    ),
  );
  return (
    <section class="single-column">
      {refresh.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{refresh.error}</span>
          <button type="button" onClick$={() => (refresh.error = "")}>
            ×
          </button>
        </div>
      )}
      <div class="integration-grid">
        {refreshableIntegrations.map((integration) => {
          const canRefresh = true;
          const status = refresh.statuses[integration.id];
          const presentation = refreshPresentation(status);
          const stateIcon: IconName =
            status?.state === "succeeded"
              ? "check"
              : status?.state === "failed"
                ? "alert"
                : "refresh";
          return (
            <article
              class={{
                "integration-card": true,
                [presentation.tone]: canRefresh && integration.available,
              }}
              aria-busy={presentation.busy ? "true" : undefined}
              key={integration.id}
            >
              <div
                class={{
                  "integration-icon": true,
                  spinning: status?.state === "running",
                }}
              >
                <Icon name={stateIcon} size={20} />
              </div>
              <div class="integration-copy">
                <h3>{integration.label}</h3>
                <p class="integration-capabilities">
                  {integration.capabilities.join(" · ") ||
                    "No manual adapter registered"}
                </p>
                {canRefresh && integration.available && (
                  <div
                    class={{
                      "refresh-feedback": true,
                      [presentation.tone]: true,
                    }}
                    role="status"
                    aria-live="polite"
                  >
                    <strong>{presentation.label}</strong>
                    <span>{presentation.detail}</span>
                  </div>
                )}
              </div>
              <button
                class="secondary-button compact-action"
                type="button"
                disabled={!integration.available || presentation.busy}
                onClick$={() => triggerRefresh(integration)}
              >
                {presentation.action}
              </button>
            </article>
          );
        })}
      </div>
      {refreshableIntegrations.length === 0 && (
        <EmptyState
          title="No refreshable applications"
          detail="Applications with a manual refresh adapter appear here once they are enabled on the server."
        />
      )}
    </section>
  );
});

const EmptyState = component$<{ title: string; detail: string }>((props) => (
  <div class="empty-state">
    <span class="empty-glyph">
      <Icon name="library" size={23} />
    </span>
    <h4>{props.title}</h4>
    <p>{props.detail}</p>
  </div>
));

const LoadingState = component$(() => (
  <div class="loading-grid" aria-label="Loading Media Manager">
    <span />
    <span />
    <span />
    <span />
  </div>
));

function readableError(error: unknown): string {
  if (error instanceof ApiError) {
    return `${error.message} (${error.code}, ${error.requestId})`;
  }
  return error instanceof Error
    ? error.message
    : "The request could not be completed.";
}

function profileForCategory(category?: string): NamingProfile {
  switch (category) {
    case "videos":
      return "movie";
    case "music":
      return "music";
    case "audiobooks":
      return "audiobook";
    case "books":
      return "book";
    default:
      return "filename";
  }
}

function profilesForCategory(
  category?: string,
): Array<{ id: NamingProfile; label: string }> {
  switch (category) {
    case "videos":
      return [
        { id: "movie", label: "Movie" },
        { id: "tv", label: "TV episode" },
      ];
    case "music":
      return [{ id: "music", label: "Music track" }];
    case "audiobooks":
      return [{ id: "audiobook", label: "Audiobook" }];
    case "books":
      return [{ id: "book", label: "Book" }];
    default:
      return [{ id: "filename", label: "File" }];
  }
}

function renameReady(state: DashboardState): boolean {
  if (!state.editTitle.trim()) return false;
  if (
    state.editYear &&
    (Number(state.editYear) < 1 || Number(state.editYear) > 2100)
  )
    return false;
  switch (state.editProfile) {
    case "tv":
      return (
        state.editSeason !== "" &&
        state.editEpisode !== "" &&
        Number(state.editEpisode) > 0
      );
    case "music":
      return Boolean(
        state.editCreator.trim() &&
          state.editCollection.trim() &&
          Number(state.editTrack) > 0,
      );
    case "audiobook":
    case "book":
      return Boolean(state.editCreator.trim());
    default:
      return true;
  }
}

function numericValue(value: string, length: number): string {
  return value.replace(/\D/g, "").slice(0, length);
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

function commaSeparated(value: string): string[] {
  return value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}
