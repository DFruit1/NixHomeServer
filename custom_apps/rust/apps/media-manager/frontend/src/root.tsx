import {
  $,
  component$,
  type QRL,
  useOnDocument,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
  useOnWindow,
} from "@builder.io/qwik";
import { api, ApiError } from "./api";
import tmdbLogo from "./tmdb-logo.svg";

export type View =
  | "library"
  | "conversions"
  | "subtitles"
  | "accounts"
  | "refresh"
  | "player";

const VIEWS = new Set<View>([
  "library",
  "conversions",
  "subtitles",
  "accounts",
  "refresh",
  "player",
]);

export function viewFromSearch(search: string): View {
  const view = new URLSearchParams(search).get("view") as View | null;
  return view && VIEWS.has(view) ? view : "library";
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

interface ProviderCredentialField {
  id: string;
  label: string;
  inputType: "password" | "text";
  isRequired: boolean;
  help: string;
}

interface ProviderAccountState {
  state: "notRequired" | "notConfigured" | "configured";
  configuredAt?: number;
  updatedAt?: number;
  lastTestedAt?: number | null;
  lastTestStatus?: "ready" | "rejected" | "rateLimited" | "unavailable" | null;
  lastTestMessage?: string | null;
}

interface ProviderDefinition {
  id: string;
  name: string;
  mediaDomains: string[];
  setupKind: "public" | "apiKey" | "account";
  implementationStatus: "active" | "planned";
  canConfigure: boolean;
  canTest: boolean;
  capabilities: string[];
  credentialFields: ProviderCredentialField[];
  setupUrl: string;
  documentationUrl: string;
  notes: string;
  account: ProviderAccountState;
}

interface ProviderCatalogResponse {
  schemaVersion: number;
  providers: ProviderDefinition[];
  recoveryAdvice: string;
  requestId: string;
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
  subtitleStreams?: Array<{
    index: number;
    codec: string;
    language?: string;
    title?: string;
    isDefault: boolean;
    isForced: boolean;
    isHearingImpaired: boolean;
  }>;
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
  metadataDraftDirty: boolean;
  metadataDraftRevision: number;
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
    destinationRelativePath?: string;
    replacementRelativePath?: string;
    archivedRelativePath?: string;
  }>;
  warnings: string[];
  affectedConsumers?: MetadataConsumer[];
}

interface MetadataObservation {
  source: string;
  label: string;
  observedAt?: number;
  relativePath?: string;
  format?: string;
  appItemId?: string;
  storage?: string;
  consumedBy?: string[];
  survivesRescan?: boolean;
  writable?: boolean;
  locked?: boolean;
  fields: Record<string, unknown>;
  rawPreview?: string;
}

interface MetadataHealthIssue {
  code: string;
  severity: "info" | "warning" | "error";
  field?: string;
  title: string;
  message: string;
  sources: string[];
}

interface MetadataModificationTarget {
  id: string;
  label: string;
  kind: "portable-file" | "application-local";
  available: boolean;
  recommended: boolean;
  requiresRefresh: boolean;
  message: string;
}

interface MetadataConsumer {
  id: string;
  label: string;
  available: boolean;
  effect: string;
  canManageNatively: boolean;
  portableWriteSupported: boolean;
  message: string;
  nativeUrl?: string;
}

interface MetadataSidecarInspection {
  relativePath: string;
  format: string;
  exists: boolean;
  canReplace: boolean;
  consumerEffective: boolean;
}

const NAV_ITEMS: Array<{ id: View; label: string; icon: IconName }> = [
  { id: "library", label: "Libraries", icon: "library" },
  { id: "conversions", label: "Conversions", icon: "disc" },
  { id: "subtitles", label: "Subtitles", icon: "captions" },
  { id: "player", label: "Player", icon: "play" },
  { id: "accounts", label: "Metadata sources", icon: "shield" },
  { id: "refresh", label: "App refresh", icon: "refresh" },
];

type IconName =
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
  | "chevron-right"
  | "audiobookshelf"
  | "jellyfin"
  | "kavita"
  | "syncthing"
  | "play"
  | "pause"
  | "skip-back"
  | "skip-forward"
  | "volume"
  | "shuffle"
  | "repeat"
  | "repeat-one"
  | "timer"
  | "album";

const Icon = component$<{ name: IconName; size?: number }>((props) => {
  const paths: Record<IconName, string[]> = {
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
    audiobookshelf: [
      "M3 18v-6a9 9 0 0 1 18 0v6",
      "M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3zM3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z",
    ],
    jellyfin: [
      "M12 2L2 7l10 5 10-5-10-5z",
      "M2 17l10 5 10-5",
      "M2 12l10 5 10-5",
    ],
    kavita: ["M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20"],
    syncthing: [
      "M21 2v6h-6",
      "M3 12a9 9 0 0 1 15-6.7L21 8",
      "M3 22v-6h6",
      "M21 12a9 9 0 0 1-15 6.7L3 16",
    ],
    play: ["M8 5v14l11-7z"],
    pause: ["M6 5h4v14H6z", "M14 5h4v14h-4z"],
    "skip-back": ["M19 20V4l-9 7-1-7H7v16h2l1-7z"],
    "skip-forward": ["M5 4v16l9-7 1 7h2V4h-2l-1 7z"],
    volume: [
      "M11 5 6 9H2v6h4l5 4z",
      "M19.07 4.93a10 10 0 0 1 0 14.14",
      "M15.54 8.46a5 5 0 0 1 0 7.07",
    ],
    shuffle: [
      "M16 3h5v5",
      "M4 20 21 3",
      "M21 16v5h-5",
      "M15 15 21 21",
      "M4 4l5 5",
    ],
    repeat: [
      "m17 2 4 4-4 4",
      "M3 11V9a4 4 0 0 1 4-4h14",
      "m7 22-4-4 4-4",
      "M21 13v2a4 4 0 0 1-4 4H3",
    ],
    "repeat-one": [
      "m17 2 4 4-4 4",
      "M3 11V9a4 4 0 0 1 4-4h14",
      "m7 22-4-4 4-4",
      "M21 13v2a4 4 0 0 1-4 4H3",
      "M11 10h1v4",
    ],
    timer: ["M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Z", "M12 6v6l4 2"],
    album: [
      "M11 5 6 9H2v6h4l5 4z",
      "M18 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12Z",
      "M18 11a1 1 0 1 0 0 2 1 1 0 0 0 0-2Z",
    ],
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
  const view = useSignal<View>(props.initialView ?? "library");
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
    metadataDraftDirty: false,
    metadataDraftRevision: 0,
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

  useOnWindow(
    "beforeunload",
    $((event: BeforeUnloadEvent) => {
      if (!state.metadataDraftDirty) return;
      event.preventDefault();
      event.returnValue = "";
    }),
  );

  const loadCategoryItems = $(async (category: string) => {
    const changingCategory = category !== state.selectedCategory;
    if (
      changingCategory &&
      !allowMetadataDraftDiscard(state.metadataDraftDirty)
    )
      return;
    if (changingCategory) state.metadataDraftDirty = false;
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
    const changingItem = item.id !== state.selectedItemId;
    if (changingItem && !allowMetadataDraftDiscard(state.metadataDraftDirty))
      return;
    if (changingItem) state.metadataDraftDirty = false;
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
    if (!allowMetadataDraftDiscard(state.metadataDraftDirty)) return;
    const selectedItemId = state.selectedItemId;
    const metadataDraftRevision = state.metadataDraftRevision;
    state.confirming = true;
    state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(state.preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${state.preview.digest}"` },
      });
      state.preview = undefined;
      if (
        state.selectedItemId !== selectedItemId ||
        state.metadataDraftRevision !== metadataDraftRevision
      ) {
        state.notice =
          "The rename was added to the mutation queue. Newer draft edits remain unsaved, or a newer selection was left in place.";
        return;
      }
      state.notice = "The rename was added to the global mutation queue.";
      state.metadataDraftDirty = false;
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

      <main
        class={{
          "main-content": true,
          "main-content--library": view.value === "library",
          "main-content--conversions": view.value === "conversions",
        }}
      >
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
        ) : view.value === "player" ? (
          <PlayerView state={state} />
        ) : view.value === "accounts" ? (
          <ProviderAccountsView />
        ) : (
          <RefreshView integrations={state.status?.integrations ?? []} />
        )}
      </main>
    </div>
  );
});

const ProviderAccountsView = component$(() => {
  const accounts = useStore<{
    providers: ProviderDefinition[];
    recoveryAdvice: string;
    selectedProviderId: string;
    credentialValues: Record<string, string>;
    query: string;
    filter: "available" | "configured" | "planned" | "all";
    testAfterSave: boolean;
    loading: boolean;
    saving: boolean;
    busyProviderId: string;
    error: string;
    notice: string;
  }>({
    providers: [],
    recoveryAdvice:
      "Saved credentials cannot be viewed again. Keep the recovery copy in Vaultwarden, KeePassXC, or another password manager.",
    selectedProviderId: "",
    credentialValues: {},
    query: "",
    filter: "available",
    testAfterSave: true,
    loading: true,
    saving: false,
    busyProviderId: "",
    error: "",
    notice: "",
  });

  const loadAccounts = $(async () => {
    const response = await api<ProviderCatalogResponse>("/provider-accounts");
    accounts.providers = response.providers;
    accounts.recoveryAdvice = response.recoveryAdvice;
  });

  useTask$(async () => {
    try {
      await loadAccounts();
    } catch (error) {
      accounts.error = readableError(error);
    } finally {
      accounts.loading = false;
    }
  });

  const closeProvider = $(() => {
    Object.keys(accounts.credentialValues).forEach(
      (key) => (accounts.credentialValues[key] = ""),
    );
    accounts.credentialValues = {};
    accounts.selectedProviderId = "";
  });

  const openProvider = $((provider: ProviderDefinition) => {
    if (!provider.canConfigure || accounts.saving) return;
    accounts.selectedProviderId = provider.id;
    accounts.testAfterSave = provider.canTest;
    accounts.credentialValues = Object.fromEntries(
      provider.credentialFields.map((field) => [field.id, ""]),
    );
    accounts.error = "";
    accounts.notice = "";
  });

  const saveProvider = $(async () => {
    const provider = accounts.providers.find(
      (candidate) => candidate.id === accounts.selectedProviderId,
    );
    if (!provider || accounts.saving) return;
    const testAfterSave = provider.canTest && accounts.testAfterSave;
    const credentials = Object.fromEntries(
      Object.entries(accounts.credentialValues).filter(
        ([, value]) => value.trim() !== "",
      ),
    );
    accounts.saving = true;
    accounts.error = "";
    try {
      const response = await api<{ provider: ProviderDefinition }>(
        `/provider-accounts/${encodeURIComponent(provider.id)}`,
        { method: "PUT", body: JSON.stringify({ credentials }) },
      );
      const index = accounts.providers.findIndex(
        (candidate) => candidate.id === provider.id,
      );
      if (index >= 0) accounts.providers[index] = response.provider;
      if (accounts.selectedProviderId === provider.id) await closeProvider();
      accounts.notice = `${provider.name} was encrypted and saved. Its values cannot be viewed from Media Manager.`;
      if (testAfterSave) {
        try {
          const test = await api<{
            status: "ready" | "rejected" | "rateLimited" | "unavailable";
            message: string;
          }>(`/provider-accounts/${encodeURIComponent(provider.id)}/test`, {
            method: "POST",
          });
          accounts.notice =
            test.status === "ready"
              ? `${provider.name} was saved and connected. ${test.message}`
              : `${provider.name} was saved, but its connection needs attention: ${test.message}`;
        } catch (error) {
          accounts.notice = `${provider.name} was encrypted and saved.`;
          accounts.error = `The saved credentials could not be tested: ${readableError(error)}`;
        }
        try {
          await loadAccounts();
        } catch (error) {
          accounts.error = `The credentials were saved, but the source status could not be refreshed: ${readableError(error)}`;
        }
      }
    } catch (error) {
      accounts.error = readableError(error);
    } finally {
      Object.keys(credentials).forEach((key) => (credentials[key] = ""));
      accounts.saving = false;
    }
  });

  const testProvider = $(async (provider: ProviderDefinition) => {
    if (accounts.saving || accounts.busyProviderId) return;
    accounts.busyProviderId = provider.id;
    accounts.error = "";
    try {
      const response = await api<{ message: string }>(
        `/provider-accounts/${encodeURIComponent(provider.id)}/test`,
        { method: "POST" },
      );
      accounts.notice = `${provider.name}: ${response.message}`;
      await loadAccounts();
    } catch (error) {
      accounts.error = readableError(error);
    } finally {
      accounts.busyProviderId = "";
    }
  });

  const deleteProvider = $(async (provider: ProviderDefinition) => {
    if (accounts.saving || accounts.busyProviderId) return;
    if (
      typeof window !== "undefined" &&
      !window.confirm(
        `Remove ${provider.name}? You will need your password-manager copy to set it up again.`,
      )
    )
      return;
    accounts.busyProviderId = provider.id;
    accounts.error = "";
    try {
      await api(`/provider-accounts/${encodeURIComponent(provider.id)}`, {
        method: "DELETE",
      });
      accounts.notice = `${provider.name} was removed.`;
      await loadAccounts();
    } catch (error) {
      accounts.error = readableError(error);
    } finally {
      accounts.busyProviderId = "";
    }
  });

  const selectedProvider = accounts.providers.find(
    (provider) => provider.id === accounts.selectedProviderId,
  );
  const query = accounts.query.trim().toLowerCase();
  const matchingProviders = query
    ? accounts.providers.filter((provider) =>
        [provider.name, ...provider.mediaDomains, ...provider.capabilities]
          .join(" ")
          .toLowerCase()
          .includes(query),
      )
    : accounts.providers;
  const providers = matchingProviders.filter((provider) => {
    switch (accounts.filter) {
      case "configured":
        return provider.account.state === "configured";
      case "planned":
        return provider.implementationStatus === "planned";
      case "all":
        return true;
      default:
        return provider.implementationStatus === "active";
    }
  });
  const configuredCount = accounts.providers.filter(
    (provider) =>
      provider.implementationStatus === "active" &&
      provider.account.state === "configured",
  ).length;
  const readyCount = accounts.providers.filter(
    (provider) =>
      provider.implementationStatus === "active" &&
      (provider.account.state === "notRequired" ||
        (provider.account.state === "configured" &&
          !["rejected", "rateLimited", "unavailable"].includes(
            provider.account.lastTestStatus ?? "",
          ))),
  ).length;

  return (
    <section class="provider-accounts-page">
      <section class="provider-account-intro panel">
        <div>
          <span class="eyebrow">Runtime configuration</span>
          <h2>Provider accounts</h2>
          <p>
            Connect your own metadata and subtitle sources. Accounts belong to
            your signed-in identity, so another user's quota or lockout does not
            affect yours.
          </p>
        </div>
        <div class="provider-account-summary">
          <strong>{configuredCount}</strong>
          <span>configured</span>
          <strong>{readyCount}</strong>
          <span>ready sources</span>
        </div>
      </section>

      <aside class="credential-guidance" role="note">
        <Icon name="shield" size={22} />
        <div>
          <strong>Keep the recovery copy in a password manager</strong>
          <p>{accounts.recoveryAdvice}</p>
          <p>
            Vaultwarden and KeePassXC are good choices. Media Manager stores an
            encrypted runtime copy, but never connects to or unlocks your vault.
          </p>
        </div>
      </aside>

      {accounts.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{accounts.error}</span>
        </div>
      )}
      {accounts.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{accounts.notice}</span>
        </div>
      )}

      <div class="provider-account-toolbar">
        <label>
          <span>Find a source</span>
          <input
            type="search"
            value={accounts.query}
            placeholder="Movies, subtitles, MusicBrainz…"
            onInput$={(_, input) => (accounts.query = input.value)}
          />
        </label>
        <span>{providers.length} shown</span>
      </div>

      <div
        class="provider-filter-tabs"
        role="group"
        aria-label="Filter metadata sources"
      >
        {(
          [
            ["available", "Available now"],
            ["configured", "Configured"],
            ["planned", "Coming soon"],
            ["all", "All sources"],
          ] as const
        ).map(([id, label]) => (
          <button
            class={{
              "provider-filter-tab": true,
              active: accounts.filter === id,
            }}
            type="button"
            aria-pressed={accounts.filter === id}
            key={id}
            onClick$={() => (accounts.filter = id)}
          >
            {label}
          </button>
        ))}
      </div>

      {accounts.loading ? (
        <LoadingState />
      ) : (
        <div class="provider-account-grid">
          {providers.map((provider) => {
            const configured = provider.account.state === "configured";
            const publicSource = provider.account.state === "notRequired";
            const connected = provider.account.lastTestStatus === "ready";
            const planned = provider.implementationStatus === "planned";
            return (
              <article class="provider-account-card" key={provider.id}>
                <div class="provider-account-card-heading">
                  <div>
                    <h3>{provider.name}</h3>
                    <span>{provider.mediaDomains.join(" · ")}</span>
                  </div>
                  <span
                    class={{
                      "provider-state": true,
                      ready: !planned && (publicSource || connected),
                      planned,
                    }}
                  >
                    {planned
                      ? configured
                        ? "Saved · adapter planned"
                        : "Adapter planned"
                      : publicSource
                        ? "Public"
                        : connected
                          ? "Connected"
                          : configured
                            ? "Configured"
                            : "Not configured"}
                  </span>
                </div>
                <p>{provider.notes}</p>
                <ul class="provider-capabilities">
                  {provider.capabilities.slice(0, 5).map((capability) => (
                    <li key={capability}>{capability.replaceAll("-", " ")}</li>
                  ))}
                </ul>
                {provider.account.lastTestMessage && (
                  <p class="provider-last-test">
                    <strong>Last test:</strong>{" "}
                    {provider.account.lastTestMessage}
                  </p>
                )}
                <div class="provider-account-actions">
                  {provider.canConfigure &&
                    provider.credentialFields.length > 0 && (
                      <button
                        class="primary-button"
                        type="button"
                        disabled={accounts.saving}
                        onClick$={() => openProvider(provider)}
                      >
                        {configured ? "Replace credentials" : "Set up"}
                      </button>
                    )}
                  {configured &&
                    provider.implementationStatus === "active" &&
                    provider.canTest && (
                      <button
                        class="secondary-button"
                        type="button"
                        disabled={
                          accounts.saving ||
                          accounts.busyProviderId === provider.id
                        }
                        onClick$={() => testProvider(provider)}
                      >
                        {accounts.busyProviderId === provider.id
                          ? "Testing…"
                          : "Test connection"}
                      </button>
                    )}
                  <a
                    href={provider.documentationUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Documentation
                  </a>
                  {configured && (
                    <button
                      class="text-button danger"
                      type="button"
                      disabled={
                        accounts.saving ||
                        accounts.busyProviderId === provider.id
                      }
                      onClick$={() => deleteProvider(provider)}
                    >
                      Remove
                    </button>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}

      {selectedProvider && (
        <section class="provider-credential-editor panel">
          <div class="panel-heading">
            <div>
              <span class="eyebrow">Write-only credentials</span>
              <h3>{selectedProvider.name}</h3>
              <p>
                Existing values are never loaded into this form. Saving replaces
                the complete set.
              </p>
            </div>
            <button
              class="close-button"
              type="button"
              aria-label="Close credential editor"
              disabled={accounts.saving}
              onClick$={closeProvider}
            >
              ×
            </button>
          </div>
          <ol class="provider-setup-steps" aria-label="Provider setup steps">
            <li>
              <span>1</span>
              <div>
                <strong>Get access</strong>
                <p>
                  Open the provider's account page and create the requested
                  credentials.
                </p>
                <a
                  href={selectedProvider.setupUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  Open provider setup
                </a>
              </div>
            </li>
            <li>
              <span>2</span>
              <div>
                <strong>Enter credentials</strong>
                <p>
                  Paste the complete set below. Existing values cannot be
                  recovered.
                </p>
              </div>
            </li>
            <li>
              <span>3</span>
              <div>
                <strong>
                  {selectedProvider.canTest && accounts.testAfterSave
                    ? "Save and test"
                    : "Save securely"}
                </strong>
                <p>
                  {selectedProvider.canTest && accounts.testAfterSave
                    ? "Encrypt the values, then verify that the provider accepts them."
                    : "Encrypt the values for this signed-in identity."}
                </p>
              </div>
            </li>
          </ol>
          <form
            preventdefault:submit
            onSubmit$={saveProvider}
            autocomplete="off"
          >
            <div class="credential-field-grid">
              {selectedProvider.credentialFields.map((field) => (
                <label key={field.id}>
                  <span>
                    {field.label}
                    {field.isRequired ? " *" : ""}
                  </span>
                  <input
                    type={field.inputType}
                    name={`provider-${selectedProvider.id}-${field.id}`}
                    value={accounts.credentialValues[field.id] ?? ""}
                    required={field.isRequired}
                    disabled={accounts.saving}
                    autocomplete={
                      field.inputType === "password" ? "new-password" : "off"
                    }
                    spellcheck={false}
                    onInput$={(_, input) =>
                      (accounts.credentialValues[field.id] = input.value)
                    }
                  />
                  <small>{field.help}</small>
                </label>
              ))}
            </div>
            {selectedProvider.canTest && (
              <label class="provider-test-choice">
                <input
                  type="checkbox"
                  checked={accounts.testAfterSave}
                  disabled={accounts.saving}
                  onChange$={(_, input) =>
                    (accounts.testAfterSave = input.checked)
                  }
                />
                <span>Test the connection after saving</span>
              </label>
            )}
            <div class="provider-credential-footer">
              <span>Credentials are encrypted before storage.</span>
              <div>
                <button
                  class="secondary-button"
                  type="button"
                  disabled={accounts.saving}
                  onClick$={closeProvider}
                >
                  Cancel
                </button>
                <button
                  class="primary-button"
                  type="submit"
                  disabled={accounts.saving}
                >
                  {accounts.saving
                    ? "Encrypting…"
                    : selectedProvider.canTest && accounts.testAfterSave
                      ? "Save and test"
                      : "Encrypt and save"}
                </button>
              </div>
            </div>
          </form>
        </section>
      )}
    </section>
  );
});

interface InstalledSubtitle {
  source: "external" | "embedded";
  itemId?: string;
  relativePath?: string;
  streamIndex?: number;
  sizeBytes?: number;
  format?: string | null;
  language?: string | null;
  title?: string | null;
  isDefault: boolean;
  isForced: boolean;
  isHearingImpaired: boolean;
  isPreviewable: boolean;
}

interface InstalledSubtitleContent {
  cues: SubtitleCue[];
  truncated: boolean;
  validation: {
    cueCount: number;
    issueCount: number;
    issues: Array<{ cueIndex: number; kind: string; message: string }>;
  };
}

const SubtitleCard = component$<{
  items: CatalogItem[];
  selectedItemId: string;
}>((props) => {
  const inspector = useStore<{
    loading: boolean;
    subtitles: InstalledSubtitle[];
    consumers: MetadataConsumer[];
    selected?: InstalledSubtitle;
    content?: InstalledSubtitleContent;
    error: string;
  }>({ loading: false, subtitles: [], consumers: [], error: "" });
  const selectedItem = props.items.find(
    (item) => item.id === props.selectedItemId,
  );
  useTask$(async ({ track }) => {
    const selectedItemId = track(() => props.selectedItemId);
    inspector.subtitles = [];
    inspector.consumers = [];
    inspector.selected = undefined;
    inspector.content = undefined;
    inspector.error = "";
    if (!selectedItemId) return;
    const item = props.items.find(
      (candidate) => candidate.id === selectedItemId,
    );
    if (item?.mediaKind !== "video") return;
    inspector.loading = true;
    try {
      const response = await api<{
        subtitles?: InstalledSubtitle[];
        consumers?: MetadataConsumer[];
      }>(`/items/${encodeURIComponent(selectedItemId)}/subtitles`);
      if (props.selectedItemId !== selectedItemId) return;
      inspector.subtitles = response.subtitles ?? [];
      inspector.consumers = response.consumers ?? [];
    } catch (error) {
      if (props.selectedItemId === selectedItemId)
        inspector.error = readableError(error);
    } finally {
      if (props.selectedItemId === selectedItemId) inspector.loading = false;
    }
  });

  const inspectContent = $(async (subtitle: InstalledSubtitle) => {
    if (!subtitle.itemId || !subtitle.isPreviewable) return;
    inspector.selected = subtitle;
    inspector.content = undefined;
    inspector.error = "";
    try {
      inspector.content = await api<InstalledSubtitleContent>(
        `/items/${encodeURIComponent(props.selectedItemId)}/subtitles/installed/${encodeURIComponent(subtitle.itemId)}/content`,
      );
    } catch (error) {
      inspector.error = readableError(error);
    }
  });

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
  return (
    <div class="subtitle-card-body installed-subtitle-inspector">
      <div class="installed-subtitle-heading">
        <div>
          <h3>Installed subtitles</h3>
          <p>
            External files and embedded streams, including flags and validation.
          </p>
        </div>
        {inspector.consumers[0]?.nativeUrl && (
          <a
            class="secondary-button"
            href={inspector.consumers[0].nativeUrl}
            target="_blank"
            rel="noreferrer"
          >
            Manage in {inspector.consumers[0].label}
          </a>
        )}
      </div>
      {inspector.error && <p class="error-copy">{inspector.error}</p>}
      {inspector.loading ? (
        <div class="subtitle-empty">
          <Icon name="refresh" size={24} />
          <span>Inspecting subtitle streams and files…</span>
        </div>
      ) : inspector.subtitles.length === 0 ? (
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>No subtitles found for this file</span>
        </div>
      ) : (
        <ul class="subtitle-list">
          {inspector.subtitles.map((subtitle, index) => {
            const filename =
              subtitle.relativePath?.split("/").at(-1) ??
              subtitle.title ??
              `Embedded stream ${subtitle.streamIndex ?? index}`;
            return (
              <li
                class="subtitle-item installed-subtitle-row"
                key={
                  subtitle.itemId ?? `stream-${subtitle.streamIndex ?? index}`
                }
              >
                <span class="subtitle-lang">
                  {(subtitle.language ?? "und").toUpperCase()}
                </span>
                <span class="subtitle-filename">
                  <strong>{filename}</strong>
                  <small>
                    {[
                      subtitle.source,
                      subtitle.format?.toUpperCase(),
                      subtitle.isDefault ? "default" : "",
                      subtitle.isForced ? "forced" : "",
                      subtitle.isHearingImpaired ? "SDH/CC" : "",
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </small>
                </span>
                {subtitle.isPreviewable && (
                  <button
                    class="secondary-button"
                    type="button"
                    onClick$={() => inspectContent(subtitle)}
                  >
                    Inspect cues
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {inspector.content && (
        <section class="installed-subtitle-content">
          <div>
            <strong>
              {inspector.content.validation.cueCount} cues ·{" "}
              {inspector.content.validation.issueCount} issues
            </strong>
            <button
              class="close-button"
              type="button"
              aria-label="Close installed subtitle preview"
              onClick$={() => (inspector.content = undefined)}
            >
              ×
            </button>
          </div>
          {inspector.content.validation.issues.length > 0 && (
            <ul class="subtitle-validation-list">
              {inspector.content.validation.issues.map((issue) => (
                <li key={`${issue.cueIndex}-${issue.kind}`}>
                  Cue {issue.cueIndex}: {issue.message}
                </li>
              ))}
            </ul>
          )}
          <ol class="subtitle-cue-list">
            {inspector.content.cues.map((cue) => (
              <li class="subtitle-cue" key={`${cue.index}-${cue.startMs}`}>
                <time>
                  {formatCueTime(cue.startMs)} → {formatCueTime(cue.endMs)}
                </time>
                <span>{cue.text || "—"}</span>
              </li>
            ))}
          </ol>
        </section>
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

function findTreeNode(nodes: TreeNode[], path: string): TreeNode | undefined {
  for (const node of nodes) {
    if (node.path === path) return node;
    const match = findTreeNode(node.children, path);
    if (match) return match;
  }
  return undefined;
}

function itemFocusPath(item: CatalogItem): string {
  const slash = item.relativePath.lastIndexOf("/");
  return slash > 0 ? item.relativePath.slice(0, slash) : "";
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
  { id: "podcasts", label: "Podcasts", icon: "audiobookshelf" },
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
  focusPath?: string;
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
  const focusedNode = props.focusPath
    ? findTreeNode(tree, props.focusPath)
    : undefined;
  const displayedTree = focusedNode ? [focusedNode] : tree;
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
            {!props.focusPath && folders.length > 1 && (
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
              {displayedTree.map((node) => (
                <TreeBranch
                  node={node}
                  depth={0}
                  browser={props.browser}
                  selectedItemId={props.selectedItemId}
                  selectedFolder={props.browser.selectedFolder}
                  selectItem$={props.selectItem$}
                  selectFolder$={props.selectFolder$}
                  parentPath=""
                  siblingPaths={displayedTree
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

const LibraryDetailPane = component$<{
  placement: "personal" | "shared";
  state: DashboardState;
  selectedItem?: CatalogItem;
  activeFolder: string;
  activeFolderRootId?: string;
  imageTitle: string;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
  closeFolderEditor$: QRL<() => void>;
}>((props) => (
  <div
    class={{
      "library-detail-pane": true,
      "detail-personal": props.placement === "personal",
      "detail-shared": props.placement === "shared",
    }}
    aria-label={`Selected ${props.placement === "personal" ? "shared" : "personal"} library details`}
  >
    <div class="root-picker-image">
      <MediaImage
        imageId={artworkCandidateId(
          props.state.items,
          props.state.selectedItemId,
          props.activeFolder,
        )}
        title={props.imageTitle}
      />
    </div>
    {props.selectedItem &&
      ["video", "music", "audiobook", "podcast", "book"].includes(
        props.selectedItem.mediaKind,
      ) && (
        <ItemEditor
          state={props.state}
          previewRename$={props.previewRename$}
          confirmRename$={props.confirmRename$}
        />
      )}
    {props.selectedItem?.mediaKind === "artwork" && (
      <ArtworkFileCard item={props.selectedItem} state={props.state} />
    )}
    {!props.selectedItem && props.activeFolder && props.activeFolderRootId && (
      <ItemEditor
        state={props.state}
        previewRename$={props.previewRename$}
        confirmRename$={props.confirmRename$}
        folder={{
          rootId: props.activeFolderRootId,
          relativePath: props.activeFolder,
        }}
        close$={props.closeFolderEditor$}
      />
    )}
  </div>
));

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
  const selectedItemRoot = props.state.roots.find(
    (root) => root.id === selectedItem?.rootId,
  );
  const activeFolder = personal.selectedFolder || shared.selectedFolder;
  const activeScope = personal.selectedFolder
    ? "personal"
    : shared.selectedFolder
      ? "shared"
      : selectedItemRoot?.scope;
  const activeFocusPath =
    activeFolder || (selectedItem ? itemFocusPath(selectedItem) : "");
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
    const changingSelection =
      personal.selectedFolder !== path ||
      shared.selectedFolder !== "" ||
      props.state.selectedItemId !== "";
    if (
      changingSelection &&
      !allowMetadataDraftDiscard(props.state.metadataDraftDirty)
    )
      return;
    if (changingSelection) props.state.metadataDraftDirty = false;
    personal.selectedFolder = path;
    shared.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const selectSharedFolder$ = $((path: string) => {
    const changingSelection =
      shared.selectedFolder !== path ||
      personal.selectedFolder !== "" ||
      props.state.selectedItemId !== "";
    if (
      changingSelection &&
      !allowMetadataDraftDiscard(props.state.metadataDraftDirty)
    )
      return;
    if (changingSelection) props.state.metadataDraftDirty = false;
    shared.selectedFolder = path;
    personal.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const selectPersonalItem$ = $((item: CatalogItem) => {
    const changingSelection =
      item.id !== props.state.selectedItemId ||
      personal.selectedFolder !== "" ||
      shared.selectedFolder !== "";
    if (
      changingSelection &&
      !allowMetadataDraftDiscard(props.state.metadataDraftDirty)
    )
      return;
    if (changingSelection) props.state.metadataDraftDirty = false;
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.selectItem$(item);
  });
  const selectSharedItem$ = $((item: CatalogItem) => {
    const changingSelection =
      item.id !== props.state.selectedItemId ||
      personal.selectedFolder !== "" ||
      shared.selectedFolder !== "";
    if (
      changingSelection &&
      !allowMetadataDraftDiscard(props.state.metadataDraftDirty)
    )
      return;
    if (changingSelection) props.state.metadataDraftDirty = false;
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.selectItem$(item);
  });
  const closeFolderEditor$ = $(() => {
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    props.state.metadataDraftDirty = false;
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
      {activeScope === "shared" ? (
        <LibraryDetailPane
          placement="personal"
          state={props.state}
          selectedItem={selectedItem}
          activeFolder={activeFolder}
          activeFolderRootId={activeFolderRootId}
          imageTitle={imageTitle}
          previewRename$={props.previewRename$}
          confirmRename$={props.confirmRename$}
          closeFolderEditor$={closeFolderEditor$}
        />
      ) : (
        <LibraryPane
          title="Personal"
          subtitle="No personal media files found"
          browser={personal}
          items={personalItems}
          focusPath={activeScope === "personal" ? activeFocusPath : ""}
          selectedItemId={props.state.selectedItemId}
          selectItem$={selectPersonalItem$}
          selectFolder$={selectPersonalFolder$}
        />
      )}
      {activeScope === "personal" ? (
        <LibraryDetailPane
          placement="shared"
          state={props.state}
          selectedItem={selectedItem}
          activeFolder={activeFolder}
          activeFolderRootId={activeFolderRootId}
          imageTitle={imageTitle}
          previewRename$={props.previewRename$}
          confirmRename$={props.confirmRename$}
          closeFolderEditor$={closeFolderEditor$}
        />
      ) : (
        <LibraryPane
          title="Shared"
          subtitle="No shared media files found"
          browser={shared}
          items={sharedItems}
          focusPath={activeScope === "shared" ? activeFocusPath : ""}
          selectedItemId={props.state.selectedItemId}
          selectItem$={selectSharedItem$}
          selectFolder$={selectSharedFolder$}
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
  const percent = Math.max(0, Math.min(100, props.conversion.percent ?? 0));
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
            <p>
              Converting {isoName}{" "}
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
                  <span class="conversion-queue__file">({item.isoName})</span>
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
            <p class="message error" role="alert">
              {error.value}
            </p>
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
      // Polling is a browser lifecycle concern. Starting an interval during SSR
      // (or a DOM-less component test) leaves work alive after the render ends.
      if (typeof window === "undefined") return;
      const timer = setInterval(load, 5000);
      cleanup(() => {
        stopped = true;
        clearInterval(timer);
      });
    });

    const activeConversions = conv.conversions?.progress.conversions ?? [];
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
                    <a href={dvdLink} target="_blank" rel="noopener noreferrer">
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
          <ProcessedCard isos={inboxProcessed} filesBaseUrl={filesBaseUrl} />
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
        <h3 id="processed-heading">Processed</h3>
        <small>Successfully converted ISOs</small>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="processed-heading"
      tabIndex={0}
    >
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
                  <Icon name="folder" size={12} />
                  &ensp;Open output
                </a>
              ) : iso.outputDir ? (
                <span class="side-item-path">
                  <Icon name="folder" size={12} />
                  &ensp;
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
        <h3 id="failed-heading">Failed</h3>
        <small>ISOs that could not be converted</small>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="failed-heading"
      tabIndex={0}
    >
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

interface VideoSummary {
  codec?: string;
  width?: number;
  height?: number;
  fps?: number;
}

interface SubtitleSearchResponse {
  provider: string;
  query: string;
  languages: string;
  matchMethod: "movie-hash" | "title-fallback";
  results: SubtitleMatch[];
  video?: VideoProbe | null;
  videoSummary?: VideoSummary;
  requestId: string;
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

interface TmdbCandidate {
  mediaType: "movie" | "tv";
  tmdbId: number;
  title: string;
  year?: number;
  overview?: string;
  voteAverage?: number;
  voteCount?: number;
  posterPath?: string;
}

interface TmdbDetails extends TmdbCandidate {
  runtimeMinutes?: number;
  genres?: string[];
  releaseDate?: string;
  firstAirDate?: string;
  crew?: Array<{ name: string; job: string; department?: string }>;
  externalIds?: { imdbId?: string; wikidataId?: string };
}

interface BatchSubtitleResult {
  itemId: string;
  relativePath: string;
  videoSummary: VideoSummary;
  results: SubtitleMatch[];
  matchMethod: string;
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
  videoSummary?: VideoSummary;
  content?: SubtitleContent;
  contentError: string;
  preview?: MutationPreview;
  error: string;
  notice: string;
  browseMode: boolean;
  browseFilter: "all" | "none" | "sidecar" | "embedded" | "both";
  batchResults: BatchSubtitleResult[];
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

interface BrowseViewProps {
  items: CatalogItem[];
  subtitleStatus: Record<string, SubtitleStatus>;
  browseFilter: "all" | "none" | "sidecar" | "embedded" | "both";
  onFilterChange: (
    filter: "all" | "none" | "sidecar" | "embedded" | "both",
  ) => void;
  onVideoSelect: (itemId: string) => void;
  language: string;
  hearingImpaired: boolean;
  providerAvailable: boolean;
  session?: Session;
  status?: Status;
  loadVideos: (rootId: string) => Promise<void>;
  videoRoots: MediaRoot[];
  search: () => Promise<void>;
  selectProviderSubtitle: (match: SubtitleMatch) => Promise<void>;
  viewContent: (match: SubtitleMatch) => Promise<void>;
  adjustSubtitleTiming: (
    match: SubtitleMatch,
    videoFps: number,
  ) => Promise<void>;
  batchSearchSubtitles: (itemIds: string[]) => Promise<void>;
  batchResults: BatchSubtitleResult[];
  onBatchResultSelect: (result: BatchSubtitleResult) => void;
}

const BrowseView = component$<BrowseViewProps>((props) => {
  const videoItems = props.items.filter((item) => item.mediaKind === "video");
  const filteredItems = videoItems.filter((item) => {
    const status = props.subtitleStatus[item.relativePath] ?? "none";
    if (props.browseFilter === "all") return true;
    return status === props.browseFilter;
  });

  const counts = {
    all: videoItems.length,
    none: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "none",
    ).length,
    sidecar: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "sidecar",
    ).length,
    embedded: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "embedded",
    ).length,
    both: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "both",
    ).length,
  };

  return (
    <div class="browse-view">
      <div class="browse-toolbar">
        <div class="browse-filters"></div>
        <div class="browse-actions">
          {props.providerAvailable &&
            props.session?.canEdit &&
            filteredItems.length > 0 && (
              <button
                class="primary-button"
                type="button"
                onClick$={() =>
                  props.batchSearchSubtitles(filteredItems.map((i) => i.id))
                }
              >
                <Icon name="scan" size={16} /> Batch search subtitles (
                {filteredItems.length})
              </button>
            )}
          <button
            class={`filter-button ${props.browseFilter === "all" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("all")}
          >
            All ({counts.all})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "none" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("none")}
          >
            No subtitles ({counts.none})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "sidecar" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("sidecar")}
          >
            External subtitles ({counts.sidecar})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "embedded" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("embedded")}
          >
            Embedded subtitles ({counts.embedded})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "both" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("both")}
          >
            Both ({counts.both})
          </button>
        </div>
      </div>

      <div class="browse-table-container">
        <table class="browse-table" role="grid">
          <thead>
            <tr>
              <th>Video</th>
              <th>Resolution</th>
              <th>Codec</th>
              <th>FPS</th>
              <th>Subtitle Status</th>
              <th>Embedded Streams</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {filteredItems.map((item) => {
              const status = props.subtitleStatus[item.relativePath] ?? "none";
              const probe = item.videoProbe;
              return (
                <tr key={item.id} class={`browse-row status-${status}`}>
                  <td class="video-name">
                    <span class="filename">
                      {item.relativePath.split("/").pop()}
                    </span>
                    <span class="path">
                      {item.relativePath.replace(/\/[^/]+$/, "")}
                    </span>
                  </td>
                  <td>
                    {probe?.width && probe?.height
                      ? `${probe.width}×${probe.height}`
                      : "—"}
                  </td>
                  <td>{probe?.codec ?? "—"}</td>
                  <td>{probe?.fps ? `${probe.fps.toFixed(3)}` : "—"}</td>
                  <td>
                    <span class={`status-badge status-${status}`}>
                      {status === "none" && "None"}
                      {status === "sidecar" && "External"}
                      {status === "embedded" && "Embedded"}
                      {status === "both" && "Both"}
                    </span>
                  </td>
                  <td>
                    {probe?.hasEmbeddedSubtitles
                      ? probe.subtitleLanguages?.length > 0
                        ? probe.subtitleLanguages.join(", ")
                        : "Yes"
                      : "None"}
                  </td>
                  <td>
                    <div class="browse-actions">
                      {props.providerAvailable && props.session?.canEdit && (
                        <button
                          class="secondary-button small"
                          type="button"
                          onClick$={() => props.onVideoSelect(item.id)}
                        >
                          <Icon name="scan" size={14} /> Search subtitles
                        </button>
                      )}
                      {!props.providerAvailable && (
                        <a
                          class="metadata-source-setup-link"
                          href="?view=accounts"
                        >
                          Set up OpenSubtitles
                        </a>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {filteredItems.length === 0 && (
          <div class="browse-empty">
            <Icon name="captions" size={32} />
            <p>No videos match the current filter.</p>
          </div>
        )}
      </div>
      {props.batchResults.length > 0 && (
        <section
          class="batch-subtitle-results"
          aria-label="Batch search results"
        >
          <div class="panel-heading">
            <div>
              <h4>Batch candidates</h4>
              <p class="quiet-copy">
                Review one video at a time. Exact hash matches are identified;
                no result is installed without its own preview and confirmation.
              </p>
            </div>
          </div>
          <div class="subtitle-results">
            {props.batchResults.map((result) => (
              <article class="subtitle-result" key={result.itemId}>
                <div>
                  <strong>{result.relativePath.split("/").pop()}</strong>
                  <span>
                    {result.results.length} candidates · {result.matchMethod}
                  </span>
                </div>
                <button
                  class="secondary-button"
                  type="button"
                  disabled={result.results.length === 0}
                  onClick$={() => props.onBatchResultSelect(result)}
                >
                  Review candidates
                </button>
              </article>
            ))}
          </div>
        </section>
      )}
    </div>
  );
});

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
    browseMode: false,
    browseFilter: "none",
    batchResults: [],
  });

  const loadVideos = $(async (rootId: string) => {
    subtitle.rootId = rootId;
    subtitle.loadingItems = true;
    subtitle.itemId = "";
    subtitle.results = [];
    subtitle.video = undefined;
    subtitle.videoSummary = undefined;
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
    subtitle.videoSummary = undefined;
    try {
      const parameters = new URLSearchParams({ languages: subtitle.language });
      if (subtitle.query.trim()) parameters.set("query", subtitle.query.trim());
      const response = await api<SubtitleSearchResponse>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/search?${parameters}`,
      );
      subtitle.results = response.results;
      subtitle.video = response.video ?? null;
      subtitle.videoSummary = response.videoSummary;
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

  const adjustSubtitleTiming = $(
    async (match: SubtitleMatch, videoFps: number) => {
      if (!subtitle.itemId || !match.fps) return;
      subtitle.loadingContent = true;
      subtitle.contentError = "";
      try {
        subtitle.preview = await api<MutationPreview>(
          `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/adjust`,
          {
            method: "POST",
            body: JSON.stringify({
              fileId: match.fileId,
              sourceFps: match.fps,
              targetFps: videoFps,
              language: match.language || subtitle.language,
              hearingImpaired:
                subtitle.hearingImpaired || match.hearingImpaired,
            }),
          },
        );
        subtitle.notice = `Prepared a complete adjusted SRT from ${match.fps.toFixed(3)} fps to ${videoFps.toFixed(3)} fps. Review the destination, then confirm the staged sidecar.`;
      } catch (error) {
        subtitle.contentError = readableError(error);
      } finally {
        subtitle.loadingContent = false;
      }
    },
  );

  const batchSearchSubtitles = $(async (itemIds: string[]) => {
    if (itemIds.length === 0) return;
    subtitle.searching = true;
    subtitle.error = "";
    subtitle.notice = "";
    try {
      const response = await api<{
        batchResults: BatchSubtitleResult[];
        requestId: string;
      }>("/subtitles/batch-search", {
        method: "POST",
        body: JSON.stringify({
          itemIds,
          languages: subtitle.language,
        }),
      });
      subtitle.notice = `Batch search completed for ${response.batchResults.length} videos. Review each candidate set before staging an install.`;
      subtitle.batchResults = response.batchResults;
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.searching = false;
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
        <div class="subtitle-mode-toggle">
          <label class="mode-toggle">
            <input
              type="checkbox"
              checked={subtitle.browseMode}
              onChange$={(_, input) => (subtitle.browseMode = input.checked)}
            />
            <span>
              {subtitle.browseMode ? "Browse all videos" : "Single video mode"}
            </span>
          </label>
        </div>
        {subtitle.browseMode ? (
          <BrowseView
            items={subtitle.items}
            subtitleStatus={subtitle.subtitleStatus}
            browseFilter={subtitle.browseFilter}
            onFilterChange={(filter) => (subtitle.browseFilter = filter)}
            onVideoSelect={(itemId) => {
              subtitle.browseMode = false;
              subtitle.itemId = itemId;
              subtitle.results = [];
              subtitle.video = undefined;
              subtitle.videoSummary = undefined;
              subtitle.preview = undefined;
              subtitle.content = undefined;
            }}
            language={subtitle.language}
            hearingImpaired={subtitle.hearingImpaired}
            providerAvailable={providerAvailable}
            session={props.session}
            status={props.status}
            loadVideos={loadVideos}
            videoRoots={videoRoots}
            search={search}
            selectProviderSubtitle={selectProviderSubtitle}
            viewContent={viewContent}
            adjustSubtitleTiming={adjustSubtitleTiming}
            batchSearchSubtitles={batchSearchSubtitles}
            batchResults={subtitle.batchResults}
            onBatchResultSelect={(result) => {
              subtitle.browseMode = false;
              subtitle.itemId = result.itemId;
              subtitle.results = result.results;
              subtitle.videoSummary = result.videoSummary;
              subtitle.preview = undefined;
              subtitle.content = undefined;
              subtitle.notice = `${result.results.length} candidates loaded for review; choose one to preview or install.`;
            }}
          />
        ) : (
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
        )}
      </section>

      {subtitle.itemId && (
        <section class="panel subtitle-installed-panel">
          <SubtitleCard
            items={subtitle.items}
            selectedItemId={subtitle.itemId}
          />
        </section>
      )}

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
                  Your OpenSubtitles account is not set up. Subtitle uploads on
                  the right work without it. To enable search:
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
                    Open <a href="?view=accounts">Metadata sources</a>, choose
                    OpenSubtitles, and paste the values at runtime. Saved values
                    cannot be viewed again, so retain the recovery copy in
                    Vaultwarden, KeePassXC, or another password manager.
                  </li>
                  <li>
                    Return here after saving. No NixOS rebuild or shared server
                    credential is required.
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
              <div class="video-summary-card">
                <h4>Video Information</h4>
                <div class="video-summary-grid">
                  <div class="video-summary-item">
                    <span class="label">Codec</span>
                    <span class="value">
                      {subtitle.video.codec ?? "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Resolution</span>
                    <span class="value">
                      {subtitle.video.width && subtitle.video.height
                        ? `${subtitle.video.width}×${subtitle.video.height}`
                        : "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Frame Rate</span>
                    <span class="value">
                      {subtitle.video.fps
                        ? `${subtitle.video.fps.toFixed(3)} fps`
                        : "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Embedded Subtitles</span>
                    <span class="value">
                      {subtitle.video.hasEmbeddedSubtitles
                        ? subtitle.video.subtitleLanguages?.length > 0
                          ? subtitle.video.subtitleLanguages.join(", ")
                          : "Yes (embedded)"
                        : "None"}
                    </span>
                  </div>
                </div>
              </div>
            )}
            {subtitle.results.map((match) => (
              <article
                class={`subtitle-result ${match.fpsCompatible === false ? "fps-mismatch" : ""} ${match.fpsCompatible === true ? "fps-match" : ""}`}
                key={`${match.providerId}-${match.fileId}`}
              >
                <div class="subtitle-result-header">
                  <strong>{match.release || match.fileName}</strong>
                  <div class="subtitle-badges">
                    {match.fpsCompatible === false && (
                      <span
                        class="badge warning"
                        title="Frame rate mismatch - subtitle timing may drift"
                      >
                        <Icon name="alert" size={12} /> fps mismatch
                      </span>
                    )}
                    {match.fpsCompatible === true && (
                      <span
                        class="badge success"
                        title="Frame rate matches video"
                      >
                        <Icon name="check" size={12} /> fps match
                      </span>
                    )}
                    {match.hashMatched && (
                      <span class="badge info" title="Exact file hash match">
                        <Icon name="shield" size={12} /> exact match
                      </span>
                    )}
                    {match.hearingImpaired && (
                      <span class="badge info" title="SDH / Hearing impaired">
                        <Icon name="captions" size={12} /> SDH
                      </span>
                    )}
                    {match.machineTranslated ||
                      (match.aiTranslated && (
                        <span class="badge warning" title="Machine translated">
                          <Icon name="alert" size={12} /> auto-translated
                        </span>
                      ))}
                  </div>
                </div>
                <div class="subtitle-meta">
                  <span>{match.language.toUpperCase()}</span>
                  {match.fps && <span> · {match.fps.toFixed(3)} fps</span>}
                  {match.subFormat && (
                    <span> · {match.subFormat.toUpperCase()}</span>
                  )}
                  {match.downloadCount && (
                    <span>
                      {" "}
                      · {match.downloadCount.toLocaleString()} downloads
                    </span>
                  )}
                  {match.votes && <span> · {match.votes} votes</span>}
                  {match.uploadDate && (
                    <span>
                      {" "}
                      · {new Date(match.uploadDate).toLocaleDateString()}
                    </span>
                  )}
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
                  {match.fpsCompatible === false && subtitle.video?.fps && (
                    <button
                      class="secondary-button"
                      type="button"
                      onClick$={() =>
                        adjustSubtitleTiming(match, subtitle.video!.fps!)
                      }
                    >
                      <Icon name="timer" size={16} /> Adjust timing
                    </button>
                  )}
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

const INSPECTED_METADATA_FIELDS = [
  "title",
  "subtitle",
  "year",
  "series",
  "volumeNumber",
  "authors",
  "narrators",
  "publisher",
  "isbn",
  "language",
  "genres",
  "tags",
  "publishedDate",
  "explicit",
  "ageRating",
  "publicationStatus",
  "description",
] as const;

const EDITABLE_METADATA_FIELDS = [
  ["mediaType", "Media type"],
  ["title", "Title"],
  ["year", "Year"],
  ["season", "Season"],
  ["episode", "Episode"],
  ["episodeTitle", "Episode title"],
  ["language", "Language code"],
  ["genres", "Genres"],
  ["authors", "Authors / artists"],
  ["narrators", "Narrators"],
  ["writers", "Writers"],
  ["series", "Series"],
  ["volumeNumber", "Volume"],
  ["publisher", "Publisher / studio"],
  ["premiereDate", "Premiere date"],
  ["runtimeMinutes", "Runtime"],
  ["officialRating", "Official rating"],
  ["communityRating", "Community rating"],
  ["isbn", "ISBN"],
  ["description", "Description"],
] as const;

const REVIEWED_METADATA_FIELDS = [
  ...EDITABLE_METADATA_FIELDS,
  ["providerIds", "Provider IDs"],
] as const;

const SOURCE_SELECTABLE_METADATA_FIELDS = EDITABLE_METADATA_FIELDS.filter(
  ([field]) => field !== "mediaType",
);

const LIST_METADATA_FIELDS = new Set([
  "authors",
  "narrators",
  "genres",
  "writers",
]);

const NUMERIC_METADATA_FIELDS = new Set([
  "year",
  "season",
  "episode",
  "runtimeMinutes",
  "communityRating",
]);

export interface MetadataFieldChange {
  field: string;
  label: string;
  before: string;
  after: string;
}

export interface MetadataSourceChoice {
  field: EditableMetadataField;
  label: string;
  options: Array<{ source: string; label: string; value: string }>;
}

function metadataSourceEditorValue(
  field: EditableMetadataField,
  value: unknown,
): string | undefined {
  let normalized: string;
  if (LIST_METADATA_FIELDS.has(field)) {
    const maximumEntries = ["authors", "narrators"].includes(field) ? 32 : 64;
    if (
      Array.isArray(value) &&
      value.some((entry) => typeof entry !== "string")
    )
      return undefined;
    if (!Array.isArray(value) && typeof value !== "string") return undefined;
    const entries = (Array.isArray(value) ? value : commaSeparated(value))
      .map((entry) => entry.trim())
      .filter(Boolean);
    if (
      entries.length > maximumEntries ||
      entries.some(
        (entry) =>
          entry.length > 500 ||
          [...entry].some(
            (character) =>
              character < " " && !["\n", "\r", "\t"].includes(character),
          ),
      )
    )
      return undefined;
    normalized = entries.join(", ");
  } else if (typeof value === "string") {
    normalized = value.trim();
  } else if (typeof value === "number" && NUMERIC_METADATA_FIELDS.has(field)) {
    normalized = Number.isFinite(value) ? String(value) : "";
  } else {
    return undefined;
  }
  if (NUMERIC_METADATA_FIELDS.has(field)) {
    const numeric = Number(normalized);
    const valid =
      Number.isFinite(numeric) &&
      (field === "communityRating"
        ? numeric >= 0 && numeric <= 10
        : Number.isInteger(numeric) &&
          (field === "year"
            ? numeric >= 1 && numeric <= 2100
            : field === "season"
              ? numeric >= 0 && numeric <= 10_000
              : numeric >= 1 && numeric <= 100_000));
    if (!valid) return undefined;
    normalized = String(numeric);
  }
  if (field === "language") {
    normalized = normalized.toLowerCase();
    if (!/^[a-z]{2,3}(?:-[a-z0-9]{2,8})?$/.test(normalized)) return undefined;
  }
  if (field === "premiereDate") {
    const date = normalized.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!date) return undefined;
    const year = Number(date[1]);
    const month = Number(date[2]);
    const day = Number(date[3]);
    const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const daysInMonth = [
      31,
      leapYear ? 29 : 28,
      31,
      30,
      31,
      30,
      31,
      31,
      30,
      31,
      30,
      31,
    ];
    if (
      year < 1 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > daysInMonth[month - 1]
    )
      return undefined;
  }
  const maximum =
    field === "description"
      ? 20_000
      : LIST_METADATA_FIELDS.has(field)
        ? 32_000
        : field === "volumeNumber"
          ? 32
          : ["isbn", "officialRating"].includes(field)
            ? 64
            : field === "language"
              ? 15
              : field === "premiereDate"
                ? 10
                : 500;
  if (
    !normalized ||
    normalized.length > maximum ||
    [...normalized].some(
      (character) => character < " " && !["\n", "\r", "\t"].includes(character),
    )
  )
    return undefined;
  return normalized;
}

export function metadataSourceChoices(
  observations: Array<Pick<MetadataObservation, "source" | "label" | "fields">>,
  currentValues: Readonly<Record<string, string>>,
): MetadataSourceChoice[] {
  return SOURCE_SELECTABLE_METADATA_FIELDS.flatMap(([field, label]) => {
    const options = observations.flatMap((observation) => {
      const value = metadataSourceEditorValue(field, observation.fields[field]);
      return value
        ? [
            {
              source: observation.source,
              label: observation.label,
              value,
            },
          ]
        : [];
    });
    if (!options.some((option) => option.value !== currentValues[field]))
      return [];
    return [{ field, label, options }];
  });
}

export function metadataFieldChanges(
  before: Readonly<Record<string, string>>,
  after: Readonly<Record<string, string>>,
): MetadataFieldChange[] {
  return REVIEWED_METADATA_FIELDS.flatMap(([field, label]) => {
    const previous = before[field] ?? "";
    const next = after[field] ?? "";
    if (previous === next) return [];
    return [
      {
        field,
        label,
        before: previous || "Not set",
        after: next || "Not set",
      },
    ];
  });
}

function allowMetadataDraftDiscard(isDirty: boolean): boolean {
  if (!isDirty) return true;
  if (typeof globalThis.confirm !== "function") return false;
  return globalThis.confirm(
    "Discard the unsaved metadata draft? This cannot be undone.",
  );
}

function metadataFieldLabel(field: string): string {
  return field
    .replace(/([A-Z])/g, " $1")
    .replace(/^./, (value) => value.toUpperCase());
}

function metadataFieldValue(value: unknown): string {
  if (Array.isArray(value)) return value.map(String).join(", ");
  if (value && typeof value === "object") return JSON.stringify(value);
  if (value == null || value === "") return "—";
  return String(value);
}

function metadataDuration(value: unknown): string {
  const seconds = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = Math.floor(seconds % 60);
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

const ObservationStructuredDetails = component$<{
  fields: Record<string, unknown>;
}>((props) => {
  const audioFiles = Array.isArray(props.fields.audioFiles)
    ? (props.fields.audioFiles as Array<Record<string, unknown>>)
    : [];
  const chapters = Array.isArray(props.fields.chapters)
    ? (props.fields.chapters as Array<Record<string, unknown>>)
    : [];
  const fieldLocks =
    props.fields.fieldLocks && typeof props.fields.fieldLocks === "object"
      ? Object.entries(props.fields.fieldLocks as Record<string, unknown>)
          .filter(([, locked]) => locked === true)
          .map(([field]) => metadataFieldLabel(field))
      : [];
  const ebook =
    props.fields.ebookFile && typeof props.fields.ebookFile === "object"
      ? (props.fields.ebookFile as Record<string, unknown>)
      : undefined;
  if (
    audioFiles.length === 0 &&
    chapters.length === 0 &&
    fieldLocks.length === 0 &&
    !ebook
  ) {
    return null;
  }
  return (
    <div class="metadata-structured-details">
      {audioFiles.length > 0 && (
        <details>
          <summary>Audio files ({audioFiles.length})</summary>
          <div
            class="metadata-mini-table"
            role="table"
            aria-label="Audio files"
          >
            {audioFiles.slice(0, 50).map((file, index) => (
              <div role="row" key={`${String(file.filename)}-${index}`}>
                <strong>{String(file.filename ?? `File ${index + 1}`)}</strong>
                <span>
                  {[
                    file.discNumber ? `D${String(file.discNumber)}` : "",
                    file.trackNumber ? `T${String(file.trackNumber)}` : "",
                    file.codec ? String(file.codec).toUpperCase() : "",
                    metadataDuration(file.duration),
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
                {Boolean(file.error) && <em>{String(file.error)}</em>}
              </div>
            ))}
          </div>
        </details>
      )}
      {chapters.length > 0 && (
        <details>
          <summary>Chapters ({chapters.length})</summary>
          <div class="metadata-mini-table" role="table" aria-label="Chapters">
            {chapters.slice(0, 50).map((chapter, index) => (
              <div role="row" key={`${String(chapter.title)}-${index}`}>
                <strong>
                  {String(chapter.title ?? `Chapter ${index + 1}`)}
                </strong>
                <span>
                  {metadataDuration(chapter.start)}–
                  {metadataDuration(chapter.end)}
                </span>
              </div>
            ))}
          </div>
        </details>
      )}
      {ebook && (
        <p class="metadata-embedded-ebook">
          <strong>Companion ebook</strong> {String(ebook.filename ?? "Present")}
        </p>
      )}
      {fieldLocks.length > 0 && (
        <p class="metadata-field-locks">
          <strong>Locked fields</strong> {fieldLocks.join(", ")}
        </p>
      )}
    </div>
  );
});

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

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
  subtitleStreams: Array<Record<string, unknown>>;
  sources: string[];
  observations: MetadataObservation[];
  fieldSources: Record<string, string>;
  consumers: MetadataConsumer[];
  health: MetadataHealthIssue[];
  modificationTargets: MetadataModificationTarget[];
  inspectionWarnings: string[];
  sidecar?: MetadataSidecarInspection;
  isDraft: boolean;
  reloadKey: number;
  pendingPlanId: string;
  pendingConsumers: MetadataConsumer[];
  propagating: boolean;
  lookupMode: MusicLookupMode;
  lookupArtist: string;
  lookupTitle: string;
  candidates: MusicCandidate[];
  lookupLoading: boolean;
  lookupError: string;
  tmdbQuery: string;
  tmdbMediaType: "movie" | "tv" | "auto";
  tmdbCandidates: TmdbCandidate[];
  tmdbLoading: boolean;
  tmdbError: string;
  loadingDetails: boolean;
  planning: boolean;
  confirming: boolean;
  previewSelectionKey: string;
  preview?: MutationPreview;
  baseline: Record<string, string>;
  previewChanges: MetadataFieldChange[];
  isDirty: boolean;
  draftRevision: number;
  draftSessionRevision: number;
}

type EditableMetadataField = (typeof EDITABLE_METADATA_FIELDS)[number][0];

function editableMetadataValues(
  metadata: MetadataEditorState,
): Record<string, string> {
  const values = Object.fromEntries(
    EDITABLE_METADATA_FIELDS.map(([field]) => [field, metadata[field]]),
  );
  values.providerIds = Object.entries(metadata.providerIds)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([provider, id]) => `${provider}: ${id}`)
    .join(", ");
  return values;
}

function normalizedMetadataValues(
  metadata: MetadataEditorState,
): Record<string, string> {
  const values = editableMetadataValues(metadata);
  for (const field of [
    "title",
    "series",
    "volumeNumber",
    "publisher",
    "isbn",
    "language",
    "description",
    "episodeTitle",
    "premiereDate",
    "officialRating",
  ] as const) {
    values[field] = metadata[field].trim();
  }
  for (const field of ["authors", "narrators", "genres", "writers"] as const) {
    values[field] = commaSeparated(metadata[field]).join(", ");
  }
  for (const field of [
    "year",
    "season",
    "episode",
    "runtimeMinutes",
  ] as const) {
    values[field] = metadata[field].trim()
      ? String(Number.parseInt(metadata[field], 10))
      : "";
  }
  values.communityRating = metadata.communityRating.trim()
    ? String(Number.parseFloat(metadata.communityRating))
    : "";
  return values;
}

function markMetadataDraftDirty(
  metadata: MetadataEditorState,
  dashboard: DashboardState,
): void {
  metadata.draftRevision += 1;
  dashboard.metadataDraftRevision += 1;
  metadata.preview = undefined;
  metadata.previewSelectionKey = "";
  metadata.previewChanges = [];
  metadata.isDirty =
    metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata))
      .length > 0;
  dashboard.metadataDraftDirty = metadata.isDirty;
}

function updateMetadataDraftField(
  metadata: MetadataEditorState,
  dashboard: DashboardState,
  field: EditableMetadataField,
  value: string,
): void {
  metadata[field] = value;
  markMetadataDraftDirty(metadata, dashboard);
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
    subtitleStreams: [],
    sources: [],
    observations: [],
    fieldSources: {},
    consumers: [],
    health: [],
    modificationTargets: [],
    inspectionWarnings: [],
    isDraft: false,
    reloadKey: 0,
    pendingPlanId: "",
    pendingConsumers: [],
    propagating: false,
    lookupMode: "auto",
    lookupArtist: "",
    lookupTitle: "",
    candidates: [],
    lookupLoading: false,
    lookupError: "",
    tmdbQuery: "",
    tmdbMediaType: "auto",
    tmdbCandidates: [],
    tmdbLoading: false,
    tmdbError: "",
    loadingDetails: false,
    planning: false,
    confirming: false,
    previewSelectionKey: "",
    baseline: {},
    previewChanges: [],
    isDirty: false,
    draftRevision: 0,
    draftSessionRevision: 0,
  });

  const removeAction = useStore<{
    planning: boolean;
    confirming: boolean;
    preview?: MutationPreview;
  }>({ planning: false, confirming: false });

  const previewRemove = $(async () => {
    if (!props.state.selectedItemId || props.folder || removeAction.planning)
      return;
    removeAction.planning = true;
    props.state.error = "";
    props.state.notice = "";
    try {
      removeAction.preview = await api<MutationPreview>("/plans", {
        method: "POST",
        body: JSON.stringify({
          operation: { kind: "tombstone" },
          itemIds: [props.state.selectedItemId],
        }),
      });
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      removeAction.planning = false;
    }
  });

  const confirmRemove = $(async () => {
    if (!removeAction.preview || removeAction.confirming) return;
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    const selectionKey = metadata.itemId;
    const draftRevision = metadata.draftRevision;
    removeAction.confirming = true;
    props.state.error = "";
    try {
      await api(
        `/plans/${encodeURIComponent(removeAction.preview.id)}/confirm`,
        {
          method: "POST",
          headers: { "if-match": `"${removeAction.preview.digest}"` },
        },
      );
      removeAction.preview = undefined;
      if (
        metadata.itemId !== selectionKey ||
        metadata.draftRevision !== draftRevision
      ) {
        props.state.notice =
          "The file was queued for the library tombstone. Newer draft edits remain unsaved, or a newer selection was left in place.";
        return;
      }
      props.state.notice =
        "The file was moved to the library tombstone; it will leave the library after the next refresh.";
      props.state.metadataDraftDirty = false;
      props.state.selectedItemId = "";
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      removeAction.confirming = false;
    }
  });

  const closeEditor = $(() => {
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    props.state.metadataDraftDirty = false;
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
    track(() => metadata.reloadKey);
    if (!selectionKey) return;
    const selectionChanged = metadata.itemId !== selectionKey;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    const loadRevision = metadata.draftRevision;
    tab.value = "metadata";
    section.value = "basics";
    const item = props.folder
      ? undefined
      : props.state.items.find(
          (candidate) => candidate.id === props.state.selectedItemId,
        );
    metadata.itemId = selectionKey;
    metadata.isDraft = false;
    if (selectionChanged) {
      metadata.pendingPlanId = "";
      metadata.pendingConsumers = [];
    }
    metadata.planning = false;
    metadata.confirming = false;
    metadata.previewSelectionKey = "";
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    removeAction.planning = false;
    removeAction.confirming = false;
    removeAction.preview = undefined;
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
    metadata.subtitleStreams = [];
    metadata.sources = ["filename"];
    metadata.observations = [];
    metadata.fieldSources = {};
    metadata.consumers = [];
    metadata.health = [];
    metadata.modificationTargets = [];
    metadata.inspectionWarnings = [];
    metadata.sidecar = undefined;
    metadata.lookupMode = "auto";
    metadata.lookupArtist = "";
    metadata.lookupTitle = "";
    metadata.candidates = [];
    metadata.lookupLoading = false;
    metadata.lookupError = "";
    metadata.tmdbQuery = metadata.title;
    metadata.tmdbMediaType = metadata.mediaType === "movie" ? "movie" : "auto";
    metadata.tmdbCandidates = [];
    metadata.tmdbLoading = false;
    metadata.tmdbError = "";
    metadata.baseline = normalizedMetadataValues(metadata);
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
        visibleSelectionKey !== selectionKey ||
        metadata.draftRevision !== loadRevision
      )
        return;
      if (details.mediaType) metadata.mediaType = String(details.mediaType);
      if (details.title) metadata.title = String(details.title);
      if (details.year != null && details.year !== "")
        metadata.year = String(details.year);
      if (details.series) metadata.series = String(details.series);
      metadata.authors = Array.isArray(details.authors)
        ? (details.authors as string[]).join(", ")
        : metadata.authors;
      metadata.narrators = Array.isArray(details.narrators)
        ? (details.narrators as string[]).join(", ")
        : metadata.narrators;
      if (details.volumeNumber)
        metadata.volumeNumber = String(details.volumeNumber);
      if (details.isbn) metadata.isbn = String(details.isbn);
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
      metadata.subtitleStreams =
        (details.subtitleStreams as Array<Record<string, unknown>>) ?? [];
      metadata.sources = (details.sources as string[]) ?? ["filename"];
      metadata.observations =
        (details.observations as MetadataObservation[]) ?? [];
      metadata.fieldSources =
        (details.fieldSources as Record<string, string>) ?? {};
      metadata.consumers = (details.consumers as MetadataConsumer[]) ?? [];
      metadata.health = (details.health as MetadataHealthIssue[]) ?? [];
      metadata.modificationTargets =
        (details.modificationTargets as MetadataModificationTarget[]) ?? [];
      metadata.inspectionWarnings =
        (details.inspectionWarnings as string[]) ?? [];
      metadata.sidecar = details.sidecar as
        | MetadataSidecarInspection
        | undefined;
      metadata.lookupArtist = metadata.authors;
      metadata.lookupTitle = metadata.title;
      metadata.baseline = normalizedMetadataValues(metadata);
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

  const toggleMetadataDraft = $(() => {
    if (metadata.confirming) return;
    if (!metadata.isDraft) {
      metadata.isDraft = true;
      metadata.draftSessionRevision += 1;
      props.state.metadataDraftRevision += 1;
      return;
    }
    if (!allowMetadataDraftDiscard(metadata.isDirty)) return;
    metadata.isDraft = false;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.reloadKey += 1;
  });

  const discardMetadataDraft = $(() => {
    if (metadata.confirming) return;
    if (!allowMetadataDraftDiscard(metadata.isDirty)) return;
    metadata.isDraft = false;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.reloadKey += 1;
  });

  const previewMetadata = $(async () => {
    if (!metadata.itemId || !metadata.title.trim() || metadata.planning) return;
    const selectionKey = metadata.itemId;
    const draftRevision = metadata.draftRevision;
    metadata.planning = true;
    props.state.error = "";
    props.state.notice = "";
    const normalized = normalizedMetadataValues(metadata);
    const fields: Record<string, unknown> = {
      mediaType: normalized.mediaType,
      title: normalized.title,
      authors: commaSeparated(normalized.authors),
      narrators: commaSeparated(normalized.narrators),
      genres: commaSeparated(normalized.genres),
      writers: commaSeparated(normalized.writers),
      providerIds: metadata.providerIds,
    };
    const optional: Array<[string, string]> = [
      ["series", normalized.series],
      ["volumeNumber", normalized.volumeNumber],
      ["publisher", normalized.publisher],
      ["isbn", normalized.isbn],
      ["language", normalized.language],
      ["description", normalized.description],
      ["episodeTitle", normalized.episodeTitle],
      ["premiereDate", normalized.premiereDate],
      ["officialRating", normalized.officialRating],
    ];
    for (const [key, value] of optional) {
      if (value.trim()) fields[key] = value.trim();
    }
    if (normalized.year) fields.year = Number.parseInt(normalized.year, 10);
    if (normalized.season)
      fields.season = Number.parseInt(normalized.season, 10);
    if (normalized.episode)
      fields.episode = Number.parseInt(normalized.episode, 10);
    if (normalized.runtimeMinutes)
      fields.runtimeMinutes = Number.parseInt(normalized.runtimeMinutes, 10);
    if (normalized.communityRating)
      fields.communityRating = Number.parseFloat(normalized.communityRating);
    const changes = metadataFieldChanges(metadata.baseline, normalized);
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
        visibleSelectionKey === selectionKey &&
        metadata.draftRevision === draftRevision
      ) {
        metadata.previewSelectionKey = selectionKey;
        metadata.preview = preview;
        metadata.previewChanges = changes;
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
    const draftSessionRevision = metadata.draftSessionRevision;
    const confirmedValues = normalizedMetadataValues(metadata);
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
      if (metadata.draftSessionRevision !== draftSessionRevision) {
        props.state.notice =
          "An earlier metadata preview was added to the mutation queue. The current draft or inspection was left unchanged.";
        return;
      }
      metadata.pendingPlanId = preview.id;
      metadata.pendingConsumers =
        preview.affectedConsumers ?? metadata.consumers;
      metadata.baseline = confirmedValues;
      metadata.isDirty =
        metadataFieldChanges(
          confirmedValues,
          normalizedMetadataValues(metadata),
        ).length > 0;
      props.state.metadataDraftDirty = metadata.isDirty;
      props.state.notice = metadata.isDirty
        ? "The previewed metadata update was added to the mutation queue. Newer draft edits remain unsaved."
        : "The portable metadata update was added to the mutation queue. Refresh the affected app after the broker finishes.";
      metadata.previewSelectionKey = "";
      metadata.preview = undefined;
      metadata.previewChanges = [];
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey &&
        metadata.draftSessionRevision === draftSessionRevision
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey &&
        metadata.draftSessionRevision === draftSessionRevision
      )
        metadata.confirming = false;
    }
  });

  const refreshAndVerify = $(async () => {
    if (!metadata.pendingPlanId || metadata.propagating) return;
    const consumers = metadata.pendingConsumers.filter(
      (consumer) =>
        consumer.available && consumer.effect === "read-after-refresh",
    );
    if (consumers.length === 0) return;
    metadata.propagating = true;
    props.state.error = "";
    props.state.notice = "Waiting for the sidecar write to finish…";
    try {
      let planState = "";
      for (let attempt = 0; attempt < 60; attempt += 1) {
        const status = await api<{ state: string; error?: string }>(
          `/plans/${encodeURIComponent(metadata.pendingPlanId)}`,
        );
        planState = status.state;
        if (planState === "completed") break;
        if (planState === "failed")
          throw new Error(status.error || "The sidecar write failed.");
        await wait(500);
      }
      if (planState !== "completed")
        throw new Error(
          "The sidecar write is still queued. Try Refresh and verify again shortly.",
        );
      for (const consumer of consumers) {
        props.state.notice = `Refreshing ${consumer.label}…`;
        await api(`/integrations/${encodeURIComponent(consumer.id)}/refresh`, {
          method: "POST",
        });
        let refreshState = "";
        for (let attempt = 0; attempt < 120; attempt += 1) {
          const refresh = await api<IntegrationRefresh>(
            `/integrations/${encodeURIComponent(consumer.id)}/refresh`,
          );
          refreshState = refresh.state;
          if (refreshState === "succeeded") break;
          if (refreshState === "failed")
            throw new Error(
              refresh.message || `${consumer.label} refresh failed.`,
            );
          await wait(1000);
        }
        if (refreshState !== "succeeded")
          throw new Error(`${consumer.label} is still refreshing.`);
      }
      metadata.reloadKey += 1;
      metadata.pendingPlanId = "";
      metadata.pendingConsumers = [];
      props.state.notice =
        "Refresh completed. Current application metadata has been queried again for comparison.";
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      metadata.propagating = false;
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
    metadata.isDraft = true;
    metadata.title = candidate.title;
    metadata.authors = candidate.artist;
    if (candidate.year) metadata.year = String(candidate.year);
    if (candidate.genres.length > 0)
      metadata.genres = candidate.genres.join(", ");
    if (candidate.label) metadata.publisher = candidate.label;
    markMetadataDraftDirty(metadata, props.state);
    props.state.error = "";
    props.state.notice = `Filled the form from “${candidate.title}”. Review the fields before previewing the metadata sidecar.`;
  });

  const lookupTmdb = $(async () => {
    const query = metadata.tmdbQuery.trim() || metadata.title.trim();
    if (!query || metadata.tmdbLoading) return;
    metadata.tmdbLoading = true;
    metadata.tmdbError = "";
    props.state.error = "";
    props.state.notice = "";
    try {
      const result = await api<{
        provider: "tmdb";
        results: TmdbCandidate[];
      }>("/provider-lookups/tmdb/search", {
        method: "POST",
        body: JSON.stringify({
          query,
          mediaType: metadata.tmdbMediaType,
          year: metadata.year ? Number.parseInt(metadata.year, 10) : undefined,
        }),
      });
      metadata.tmdbCandidates = result.results;
      if (result.results.length === 0)
        props.state.notice =
          "TMDB found no candidates. Try removing the year or simplifying the title.";
    } catch (error) {
      metadata.tmdbError = readableError(error);
    } finally {
      metadata.tmdbLoading = false;
    }
  });

  const fillTmdbCandidate = $(async (candidate: TmdbCandidate) => {
    if (metadata.tmdbLoading) return;
    metadata.tmdbLoading = true;
    metadata.tmdbError = "";
    props.state.error = "";
    try {
      const response = await api<{ provider: "tmdb"; details: TmdbDetails }>(
        "/provider-lookups/tmdb/details",
        {
          method: "POST",
          body: JSON.stringify({
            tmdbId: candidate.tmdbId,
            mediaType: candidate.mediaType,
          }),
        },
      );
      const details = response.details;
      metadata.isDraft = true;
      metadata.mediaType = details.mediaType === "tv" ? "series" : "movie";
      metadata.title = details.title;
      if (details.year) metadata.year = String(details.year);
      if (details.overview) metadata.description = details.overview;
      if (details.runtimeMinutes)
        metadata.runtimeMinutes = String(details.runtimeMinutes);
      if (details.voteAverage != null)
        metadata.communityRating = String(details.voteAverage);
      if (details.genres?.length) metadata.genres = details.genres.join(", ");
      const writers = (details.crew ?? [])
        .filter((member) =>
          ["Writer", "Screenplay", "Teleplay", "Story"].includes(member.job),
        )
        .map((member) => member.name)
        .filter((name, index, names) => names.indexOf(name) === index);
      if (writers.length > 0) metadata.writers = writers.join(", ");
      metadata.premiereDate =
        details.releaseDate?.slice(0, 10) ??
        details.firstAirDate?.slice(0, 10) ??
        metadata.premiereDate;
      metadata.providerIds = {
        ...metadata.providerIds,
        tmdb: String(details.tmdbId),
        ...(details.externalIds?.imdbId
          ? { imdb: details.externalIds.imdbId }
          : {}),
        ...(details.externalIds?.wikidataId
          ? { wikidata: details.externalIds.wikidataId }
          : {}),
      };
      markMetadataDraftDirty(metadata, props.state);
      props.state.notice =
        "Filled the draft from TMDB. Review every field and preview the portable metadata change before applying it.";
    } catch (error) {
      metadata.tmdbError = readableError(error);
    } finally {
      metadata.tmdbLoading = false;
    }
  });

  const portableWriteAvailable =
    metadata.modificationTargets.length === 0
      ? !["book", "podcast"].includes(metadata.mediaType)
      : metadata.modificationTargets.some(
          (target) => target.kind === "portable-file" && target.available,
        );
  const normalizedDraftValues = normalizedMetadataValues(metadata);
  const sourceChoices = metadata.isDraft
    ? metadataSourceChoices(metadata.observations, normalizedDraftValues)
    : [];

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
        <div class="editor-heading-actions">
          {tab.value === "metadata" &&
            props.state.session?.canEdit &&
            metadata.mediaType !== "collection" &&
            metadata.mediaType !== "podcast" && (
              <button
                class="secondary-button"
                type="button"
                disabled={
                  !portableWriteAvailable ||
                  metadata.loadingDetails ||
                  metadata.confirming
                }
                onClick$={toggleMetadataDraft}
              >
                <Icon name={metadata.isDraft ? "check" : "tag"} size={17} />
                {metadata.isDraft
                  ? metadata.isDirty
                    ? "Discard draft"
                    : "Inspect current"
                  : "Create draft"}
              </button>
            )}
          <button
            class="close-button"
            type="button"
            aria-label="Close item editor"
            onClick$={closeEditor}
          >
            ×
          </button>
        </div>
      </div>

      {tab.value === "metadata" ? (
        <>
          <details class="metadata-inspector">
            <summary class="metadata-inspector-heading">
              <div>
                <span class="eyebrow">Current metadata</span>
                <h3>Sources, differences, and write targets</h3>
                <p>
                  Compare the filename, portable metadata, and connected media
                  apps when you need more context.
                </p>
              </div>
              <span class="metadata-inspector-toggle" />
            </summary>
            <div class="metadata-source-grid">
              {metadata.observations.map((observation) => (
                <article class="metadata-source-card" key={observation.source}>
                  <div>
                    <strong>{observation.label}</strong>
                    <span class="source-kind">{observation.source}</span>
                  </div>
                  <div
                    class="metadata-layer-badges"
                    aria-label="Metadata persistence"
                  >
                    {observation.storage && (
                      <span>{observation.storage.replaceAll("-", " ")}</span>
                    )}
                    {observation.survivesRescan && <span>Survives rescan</span>}
                    {observation.locked === true && <span>Locked in app</span>}
                    {observation.consumedBy?.map((consumer) => (
                      <span key={consumer}>Read by {consumer}</span>
                    ))}
                  </div>
                  <dl>
                    <div>
                      <dt>Title</dt>
                      <dd>{metadataFieldValue(observation.fields.title)}</dd>
                    </div>
                    {observation.relativePath && (
                      <div>
                        <dt>File</dt>
                        <dd>{observation.relativePath}</dd>
                      </div>
                    )}
                    {observation.appItemId && (
                      <div>
                        <dt>App ID</dt>
                        <dd>{observation.appItemId}</dd>
                      </div>
                    )}
                    {observation.observedAt && (
                      <div>
                        <dt>Observed</dt>
                        <dd>
                          {new Date(
                            observation.observedAt * 1000,
                          ).toLocaleString()}
                        </dd>
                      </div>
                    )}
                  </dl>
                  <ObservationStructuredDetails fields={observation.fields} />
                  {observation.rawPreview && (
                    <details class="metadata-raw-source">
                      <summary>
                        View raw {observation.format?.toUpperCase() ?? "source"}
                      </summary>
                      <pre>{observation.rawPreview}</pre>
                    </details>
                  )}
                </article>
              ))}
            </div>
            {(metadata.health.length > 0 ||
              metadata.inspectionWarnings.length > 0) && (
              <section class="metadata-health" aria-label="Metadata health">
                <div class="metadata-subheading">
                  <div>
                    <span class="eyebrow">Metadata health</span>
                    <h4>Checks worth reviewing</h4>
                  </div>
                  <span class="pane-count">
                    {metadata.health.length +
                      metadata.inspectionWarnings.length}
                  </span>
                </div>
                <div class="metadata-health-list">
                  {metadata.health.map((issue, index) => (
                    <article
                      class={{
                        "metadata-health-item": true,
                        [`severity-${issue.severity}`]: true,
                      }}
                      key={`${issue.code}-${index}`}
                    >
                      <Icon
                        name={issue.severity === "info" ? "scan" : "alert"}
                        size={17}
                      />
                      <div>
                        <strong>{issue.title}</strong>
                        <p>{issue.message}</p>
                        {issue.sources.length > 0 && (
                          <span>Sources: {issue.sources.join(" · ")}</span>
                        )}
                      </div>
                    </article>
                  ))}
                  {metadata.inspectionWarnings.map((warning, index) => (
                    <article
                      class="metadata-health-item severity-info"
                      key={`${warning}-${index}`}
                    >
                      <Icon name="scan" size={17} />
                      <div>
                        <strong>Source could not be inspected</strong>
                        <p>{warning}</p>
                      </div>
                    </article>
                  ))}
                </div>
              </section>
            )}
            {metadata.observations.length > 0 && (
              <div class="metadata-comparison-scroll">
                <table class="metadata-comparison">
                  <thead>
                    <tr>
                      <th>Field</th>
                      {metadata.observations.map((observation) => (
                        <th key={observation.source}>{observation.label}</th>
                      ))}
                      <th>Effective source</th>
                    </tr>
                  </thead>
                  <tbody>
                    {INSPECTED_METADATA_FIELDS.map((field) => (
                      <tr key={field}>
                        <th>{metadataFieldLabel(field)}</th>
                        {metadata.observations.map((observation) => (
                          <td key={`${observation.source}-${field}`}>
                            {metadataFieldValue(observation.fields[field])}
                          </td>
                        ))}
                        <td>
                          <span class="source-pill">
                            {metadata.fieldSources[field] ?? "—"}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <div class="metadata-consumers">
              {metadata.consumers.map((consumer) => (
                <article class="metadata-consumer" key={consumer.id}>
                  <div>
                    <strong>{consumer.label}</strong>
                    <span
                      class={{ "status-badge": true, live: consumer.available }}
                    >
                      {consumer.available ? "Connected" : "Unavailable"}
                    </span>
                  </div>
                  <p>{consumer.message}</p>
                  <footer>
                    <span>
                      {consumer.effect === "read-after-refresh"
                        ? "Refresh after applying"
                        : "Embedded-file edit required"}
                    </span>
                    {consumer.nativeUrl && consumer.canManageNatively && (
                      <a
                        href={consumer.nativeUrl}
                        target="_blank"
                        rel="noreferrer"
                      >
                        Open in {consumer.label}
                      </a>
                    )}
                  </footer>
                </article>
              ))}
            </div>
            {metadata.modificationTargets.length > 0 && (
              <section
                class="metadata-targets"
                aria-label="Modification targets"
              >
                <div class="metadata-subheading">
                  <div>
                    <span class="eyebrow">Where changes go</span>
                    <h4>Modification targets</h4>
                  </div>
                </div>
                <div class="metadata-target-list">
                  {metadata.modificationTargets.map((target) => (
                    <article
                      class={{
                        "metadata-target": true,
                        unavailable: !target.available,
                      }}
                      key={target.id}
                    >
                      <div>
                        <strong>{target.label}</strong>
                        <span class="source-kind">
                          {target.kind === "portable-file"
                            ? "Portable"
                            : "App only"}
                        </span>
                        {target.recommended && (
                          <span class="status-badge live">Recommended</span>
                        )}
                      </div>
                      <p>{target.message}</p>
                      <footer>
                        <span>
                          {!target.available
                            ? "Inspection only"
                            : target.requiresRefresh
                              ? "Refresh app after applying"
                              : "Applies inside the app"}
                        </span>
                      </footer>
                    </article>
                  ))}
                </div>
              </section>
            )}
            {metadata.mediaType === "book" && (
              <p class="metadata-compatibility-note">
                Kavita consumes metadata inside the book container, not a
                neighboring OPF. EPUB package metadata and root ComicInfo.xml in
                CBZ can be updated here with a recoverable container rebuild;
                PDF XMP and CBR remain inspection-only.
              </p>
            )}
            {metadata.mediaType === "podcast" && (
              <p class="metadata-compatibility-note">
                Podcasts remain a separate Audiobookshelf media type. Embedded
                episode tags can be inspected here; feed matching and app-local
                edits stay in Audiobookshelf until a safe portable podcast
                writer is enabled.
              </p>
            )}
          </details>
          {["movie", "series", "episode"].includes(metadata.mediaType) && (
            <section class="panel musicbrainz-panel tmdb-panel">
              <div class="panel-heading">
                <div>
                  <h3>TMDB lookup</h3>
                </div>
                <span class="status-badge live">Per-user account</span>
              </div>
              <p class="quiet-copy">
                Search with your runtime TMDB account, inspect likely matches,
                then fill a draft. Lookup results never write metadata by
                themselves. Configure or replace it in{" "}
                <a class="metadata-source-setup-link" href="?view=accounts">
                  Metadata sources
                </a>
                .
              </p>
              <div class="metadata-form">
                <label class="tmdb-query-input">
                  <span>Title</span>
                  <input
                    value={metadata.tmdbQuery || metadata.title}
                    maxLength={500}
                    placeholder="e.g. Arrival"
                    onInput$={(_, input) => (metadata.tmdbQuery = input.value)}
                  />
                </label>
                <label>
                  <span>Kind</span>
                  <select
                    value={metadata.tmdbMediaType}
                    onChange$={(_, select) =>
                      (metadata.tmdbMediaType = select.value as
                        | "movie"
                        | "tv"
                        | "auto")
                    }
                  >
                    <option value="auto">Movies and television</option>
                    <option value="movie">Movies</option>
                    <option value="tv">Television</option>
                  </select>
                </label>
                <div class="metadata-actions">
                  <button
                    class="primary-button"
                    type="button"
                    disabled={
                      !props.state.session?.canEdit ||
                      metadata.tmdbLoading ||
                      !(metadata.tmdbQuery.trim() || metadata.title.trim())
                    }
                    onClick$={lookupTmdb}
                  >
                    <Icon name="scan" size={18} />
                    {metadata.tmdbLoading ? "Looking up…" : "Find matches"}
                  </button>
                </div>
              </div>
              {metadata.tmdbError && (
                <p class="error-copy">{metadata.tmdbError}</p>
              )}
              <div class="subtitle-results">
                {metadata.tmdbCandidates.map((candidate) => (
                  <article
                    class="subtitle-result"
                    key={`${candidate.mediaType}-${candidate.tmdbId}`}
                  >
                    <div>
                      <strong>
                        {candidate.title}
                        {candidate.year ? ` (${candidate.year})` : ""}
                      </strong>
                      <span>
                        {candidate.mediaType === "tv" ? "Television" : "Movie"}
                        {candidate.voteCount != null
                          ? ` · ${candidate.voteCount.toLocaleString()} votes`
                          : ""}
                        {candidate.voteAverage != null
                          ? ` · ${candidate.voteAverage.toFixed(1)}/10`
                          : ""}
                      </span>
                      {candidate.overview && <p>{candidate.overview}</p>}
                    </div>
                    <button
                      class="secondary-button"
                      type="button"
                      disabled={metadata.tmdbLoading}
                      onClick$={() => fillTmdbCandidate(candidate)}
                    >
                      Fill draft
                    </button>
                  </article>
                ))}
                {metadata.tmdbCandidates.length === 0 && (
                  <p class="quiet-copy">
                    Candidate titles will appear here with year, popularity, and
                    summary so you can disambiguate before filling fields.
                  </p>
                )}
              </div>
              <div class="tmdb-attribution metadata-compatibility-note">
                <a
                  href="https://www.themoviedb.org"
                  target="_blank"
                  rel="noreferrer"
                  aria-label="Visit The Movie Database"
                >
                  <img src={tmdbLogo} alt="TMDB" />
                </a>
                <p>
                  This product uses the TMDB API but is not endorsed or
                  certified by TMDB.
                </p>
              </div>
            </section>
          )}
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
                audio itself but needs an AcoustID API key in{" "}
                <a class="metadata-source-setup-link" href="?view=accounts">
                  Metadata sources
                </a>
                .
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
          {metadata.isDraft && sourceChoices.length > 0 && (
            <section
              class="metadata-source-choices"
              aria-labelledby="metadata-source-choices-title"
            >
              <div class="metadata-source-choices-heading">
                <div>
                  <span class="eyebrow">Compare and merge</span>
                  <h3 id="metadata-source-choices-title">
                    Choose source values
                  </h3>
                  <p>
                    Review each field independently. Nothing is written until
                    you preview and confirm the metadata sidecar.
                  </p>
                </div>
                <span class="pane-count">{sourceChoices.length}</span>
              </div>
              <div class="metadata-source-choice-list">
                {sourceChoices.map((choice) => (
                  <article key={choice.field}>
                    <strong>{choice.label}</strong>
                    <div
                      class="metadata-source-choice-options"
                      role="group"
                      aria-label={`${choice.label} source values`}
                    >
                      {choice.options.map((option) => {
                        const isCurrent =
                          normalizedDraftValues[choice.field] === option.value;
                        return (
                          <button
                            key={`${choice.field}-${option.source}`}
                            type="button"
                            class={{
                              "metadata-source-choice": true,
                              current: isCurrent,
                            }}
                            disabled={isCurrent}
                            aria-pressed={isCurrent}
                            onClick$={() =>
                              updateMetadataDraftField(
                                metadata,
                                props.state,
                                choice.field,
                                option.value,
                              )
                            }
                          >
                            <span class="metadata-source-choice-label">
                              {option.label}
                            </span>
                            <span
                              class="metadata-source-choice-value"
                              title={option.value}
                            >
                              {option.value}
                            </span>
                            <span class="metadata-source-choice-action">
                              {isCurrent ? "In draft" : "Use value"}
                            </span>
                          </button>
                        );
                      })}
                    </div>
                  </article>
                ))}
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
          <fieldset
            class="metadata-form editor-metadata-form"
            disabled={!metadata.isDraft}
          >
            {section.value === "basics" && (
              <>
                <label>
                  <span>Media type</span>
                  <select
                    value={metadata.mediaType}
                    disabled={Boolean(props.folder)}
                    onChange$={(_, select) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "mediaType",
                        select.value,
                      )
                    }
                  >
                    <option value="movie">Movie</option>
                    <option value="collection">Collection</option>
                    <option value="series">TV series</option>
                    <option value="season">TV season</option>
                    <option value="episode">TV episode</option>
                    <option value="music">Music</option>
                    <option value="audiobook">Audiobook</option>
                    <option value="podcast">Podcast</option>
                    <option value="book">Book</option>
                  </select>
                </label>
                <label class="title-input">
                  <span>Title</span>
                  <input
                    value={metadata.title}
                    maxLength={500}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "title",
                        input.value,
                      )
                    }
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
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "year",
                        input.value.replace(/\D/g, "").slice(0, 4),
                      )
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
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "season",
                            numericValue(input.value, 4),
                          )
                        }
                      />
                    </label>
                    <label>
                      <span>Episode</span>
                      <input
                        value={metadata.episode}
                        inputMode="numeric"
                        onInput$={(_, input) =>
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "episode",
                            numericValue(input.value, 5),
                          )
                        }
                      />
                    </label>
                    <label class="title-input">
                      <span>Episode title</span>
                      <input
                        value={metadata.episodeTitle}
                        maxLength={500}
                        onInput$={(_, input) =>
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "episodeTitle",
                            input.value,
                          )
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
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "language",
                        input.value.toLowerCase().replace(/[^a-z0-9-]/g, ""),
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Genres <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.genres}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "genres",
                        input.value,
                      )
                    }
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
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "authors",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Narrators <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.narrators}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "narrators",
                        input.value,
                      )
                    }
                  />
                </label>
                <label class="title-input">
                  <span>
                    Writers <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.writers}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "writers",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Series</span>
                  <input
                    value={metadata.series}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "series",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Volume</span>
                  <input
                    value={metadata.volumeNumber}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "volumeNumber",
                        input.value,
                      )
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
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "publisher",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Premiere date</span>
                  <input
                    type="date"
                    value={metadata.premiereDate}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "premiereDate",
                        input.value,
                      )
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
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "runtimeMinutes",
                        numericValue(input.value, 6),
                      )
                    }
                  />
                </label>
                <label>
                  <span>Official rating</span>
                  <input
                    value={metadata.officialRating}
                    maxLength={64}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "officialRating",
                        input.value,
                      )
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
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "communityRating",
                        input.value.replace(/[^0-9.]/g, "").slice(0, 5),
                      )
                    }
                  />
                </label>
                <label>
                  <span>ISBN</span>
                  <input
                    value={metadata.isbn}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "isbn",
                        input.value,
                      )
                    }
                  />
                </label>
                <label class="description-input">
                  <span>Description</span>
                  <textarea
                    value={metadata.description}
                    maxLength={20000}
                    rows={5}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "description",
                        input.value,
                      )
                    }
                  />
                </label>
              </>
            )}
          </fieldset>
          <div class="metadata-actions">
            <span>
              {metadata.loadingDetails
                ? "Reading available metadata…"
                : metadata.isDirty
                  ? `${metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata)).length} unsaved field change${metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata)).length === 1 ? "" : "s"}.`
                  : `Sources: ${metadata.sources.join(" + ") || "select an item"}. NFO is used for video/music; OPF is used for books and audiobooks.`}
            </span>
            <div class="metadata-action-buttons">
              {metadata.isDirty && (
                <button
                  class="text-button"
                  type="button"
                  disabled={metadata.confirming}
                  onClick$={discardMetadataDraft}
                >
                  Discard changes
                </button>
              )}
              {metadata.pendingPlanId &&
                metadata.pendingConsumers.some(
                  (consumer) =>
                    consumer.available &&
                    consumer.effect !== "native-podcast-metadata",
                ) && (
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={metadata.propagating}
                    onClick$={refreshAndVerify}
                  >
                    <Icon name="refresh" size={18} />
                    {metadata.propagating
                      ? "Refreshing and verifying…"
                      : "Refresh and verify"}
                  </button>
                )}
              <button
                class="primary-button"
                type="button"
                disabled={
                  !props.state.session?.canEdit ||
                  !metadata.isDraft ||
                  !metadata.itemId ||
                  metadata.mediaType === "collection" ||
                  !portableWriteAvailable ||
                  !metadata.title.trim() ||
                  metadata.planning
                }
                onClick$={previewMetadata}
              >
                <Icon name="scan" size={18} />
                {metadata.mediaType === "collection"
                  ? "Grouping folder"
                  : metadata.mediaType === "book"
                    ? metadata.planning
                      ? "Rebuilding container…"
                      : "Preview embedded metadata update"
                    : metadata.planning
                      ? "Preparing…"
                      : metadata.sidecar?.exists
                        ? "Preview safe sidecar update"
                        : "Preview metadata sidecar"}
              </button>
            </div>
          </div>
          {(metadata.videoStreams.length > 0 ||
            metadata.audioStreams.length > 0 ||
            metadata.subtitleStreams.length > 0 ||
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
                {metadata.subtitleStreams.map((stream, index) => (
                  <div key={`subtitle-${index}`}>
                    <dt>Subtitle</dt>
                    <dd>
                      {[
                        stream.language
                          ? String(stream.language)
                          : "Unknown language",
                        stream.codec ? String(stream.codec) : "",
                        stream.title ? String(stream.title) : "",
                        stream.isDefault ? "default" : "",
                        stream.isForced ? "forced" : "",
                        stream.isHearingImpaired ? "SDH/CC" : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {Object.entries(metadata.providerIds).map(([provider, id]) => (
                  <div key={provider}>
                    <dt>{provider.toUpperCase()} ID</dt>
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
                    {metadata.preview.actions[0]?.replacementRelativePath}
                  </strong>
                </span>
              </div>
              <section
                class="metadata-change-review"
                aria-label="Metadata field changes"
              >
                <div class="metadata-change-review-heading">
                  <strong>Review field changes</strong>
                  <span>{metadata.previewChanges.length} changed</span>
                </div>
                {metadata.previewChanges.length > 0 ? (
                  <dl>
                    {metadata.previewChanges.map((change) => (
                      <div key={change.field}>
                        <dt>{change.label}</dt>
                        <dd>
                          <span>{change.before}</span>
                          <Icon name="arrow" size={15} />
                          <strong>{change.after}</strong>
                        </dd>
                      </div>
                    ))}
                  </dl>
                ) : (
                  <p>
                    No field values differ. This creates a portable metadata
                    copy from the currently inspected values.
                  </p>
                )}
              </section>
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

      {!props.folder && (
        <div class="editor-remove">
          <div class="editor-remove-copy">
            <Icon name="alert" size={16} />
            <span>
              Move this file into the library tombstone (<code>_Tombstone</code>
              ) to remove it from the library without deleting it. It leaves the
              library on the next refresh.
            </span>
          </div>
          {removeAction.preview ? (
            <div class="editor-remove-confirm">
              <p>
                The file will move to{" "}
                <strong>
                  {removeAction.preview.actions[0]?.destinationRelativePath}
                </strong>{" "}
                and disappear from the library after the next refresh.
              </p>
              <button
                class="primary-button danger"
                type="button"
                disabled={
                  props.state.status?.mutationMode !== "enabled" ||
                  removeAction.confirming
                }
                onClick$={confirmRemove}
              >
                <Icon name="check" size={18} />
                {removeAction.confirming ? "Queuing…" : "Confirm removal"}
              </button>
            </div>
          ) : (
            <button
              class="secondary-button danger"
              type="button"
              disabled={!props.state.session?.canEdit || removeAction.planning}
              onClick$={previewRemove}
            >
              <Icon name="alert" size={18} />
              {removeAction.planning ? "Preparing…" : "Remove from library"}
            </button>
          )}
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

  const integrationIconMap: Record<string, IconName> = {
    audiobookshelf: "audiobookshelf",
    jellyfin: "jellyfin",
    kavita: "kavita",
    syncthing: "syncthing",
  };

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
          const appIcon = integrationIconMap[integration.id] ?? "refresh";
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
                <Icon name={appIcon} size={20} />
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

const PlayerView = component$<{ state: DashboardState }>((props) => {
  const audioRef = useSignal<HTMLAudioElement>();
  const lastSavedPosition = useSignal(0);
  const saveTimerRef = useSignal<number | undefined>();
  const playerState = useStore<{
    tracks: CatalogItem[];
    currentIndex: number;
    isPlaying: boolean;
    currentTime: number;
    duration: number;
    volume: number;
    loading: boolean;
    error: string;
    selectedRootFilter: string;
    shuffle: boolean;
    loop: "off" | "one" | "all";
    sleepTimer: number;
    sleepRemaining: number;
    albumView: boolean;
    selectedAlbumDir: string;
    shuffledIndices: number[];
  }>({
    tracks: [],
    currentIndex: -1,
    isPlaying: false,
    currentTime: 0,
    duration: 0,
    volume: 1,
    loading: true,
    error: "",
    selectedRootFilter: "",
    shuffle: false,
    loop: "off",
    sleepTimer: 0,
    sleepRemaining: 0,
    albumView: true,
    selectedAlbumDir: "",
    shuffledIndices: [],
  });

  const musicRoots = props.state.roots.filter(
    (root) => root.category === "music" || root.category === "audiobooks",
  );

  const buildShuffled = $(() => {
    const n = playerState.tracks.length;
    const order = Array.from({ length: n }, (_, i) => i);
    const shuffled = [...order];
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    playerState.shuffledIndices = shuffled;
  });

  const resolveNextIndex = (fromIndex: number): number => {
    const n = playerState.tracks.length;
    if (n === 0) return -1;
    if (playerState.shuffle && playerState.shuffledIndices.length === n) {
      const pos = playerState.shuffledIndices.indexOf(fromIndex);
      return playerState.shuffledIndices[(pos + 1) % n];
    }
    return (fromIndex + 1) % n;
  };

  const resolvePrevIndex = (fromIndex: number): number => {
    const n = playerState.tracks.length;
    if (n === 0) return -1;
    if (playerState.shuffle && playerState.shuffledIndices.length === n) {
      const pos = playerState.shuffledIndices.indexOf(fromIndex);
      return playerState.shuffledIndices[(pos - 1 + n) % n];
    }
    return fromIndex <= 0 ? n - 1 : fromIndex - 1;
  };

  const loadTracks = $(async (rootId?: string) => {
    playerState.loading = true;
    playerState.error = "";
    const playingTrack = playerState.tracks[playerState.currentIndex];
    try {
      const rootsToLoad = rootId
        ? musicRoots.filter((r) => r.id === rootId)
        : musicRoots;
      const results = await Promise.all(
        rootsToLoad.map((root) =>
          api<{ items: CatalogItem[] }>(
            `/items?rootId=${encodeURIComponent(root.id)}`,
          ),
        ),
      );
      const allItems = results.flatMap((r) => r.items);
      const audioItems = allItems.filter(
        (item) => item.mediaKind === "music" || item.mediaKind === "audiobook",
      );
      audioItems.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
      playerState.tracks = audioItems;
      if (playerState.shuffle) buildShuffled();
      if (playingTrack) {
        const preservedIndex = audioItems.findIndex(
          (t) => t.id === playingTrack.id,
        );
        if (preservedIndex >= 0) {
          playerState.currentIndex = preservedIndex;
        } else {
          playerState.currentIndex = -1;
          const audio = audioRef.value;
          if (audio && !audio.paused) audio.pause();
        }
      } else if (audioItems.length > 0) {
        playerState.currentIndex = 0;
      } else {
        playerState.currentIndex = -1;
      }
    } catch (error) {
      playerState.error = readableError(error);
    } finally {
      playerState.loading = false;
    }
  });

  useTask$(async () => {
    await loadTracks();
  });

  const savePlaybackPosition = $(() => {
    const track = playerState.tracks[playerState.currentIndex];
    if (!track || track.mediaKind !== "audiobook") return;
    const pos = Math.floor(playerState.currentTime);
    if (pos <= lastSavedPosition.value) return;
    lastSavedPosition.value = pos;
    api(`/items/${encodeURIComponent(track.id)}/playback`, {
      method: "PUT",
      body: JSON.stringify({ position: pos }),
    }).catch(() => {});
  });

  const loadPlaybackPosition = $(async (track: CatalogItem): Promise<void> => {
    if (track.mediaKind !== "audiobook") return;
    try {
      const result = await api<{ position: number | null }>(
        `/items/${encodeURIComponent(track.id)}/playback`,
      );
      if (result.position != null && result.position > 0) {
        const audio = audioRef.value;
        if (audio) {
          audio.currentTime = result.position;
          playerState.currentTime = result.position;
          lastSavedPosition.value = Math.floor(result.position);
        }
      }
    } catch {
      /* position unavailable */
    }
  });

  const stopSaveTimer = $(() => {
    if (saveTimerRef.value != null) {
      clearInterval(saveTimerRef.value);
      saveTimerRef.value = undefined;
    }
  });

  const startSaveTimer = $(() => {
    stopSaveTimer();
    saveTimerRef.value = window.setInterval(() => {
      if (playerState.isPlaying) savePlaybackPosition();
    }, 10000);
  });

  const stopSleepTimer = $(() => {
    playerState.sleepTimer = 0;
    playerState.sleepRemaining = 0;
  });

  const playTrack = $((index: number) => {
    const audio = audioRef.value;
    if (!audio || index < 0 || index >= playerState.tracks.length) return;
    savePlaybackPosition();
    playerState.currentIndex = index;
    playerState.currentTime = 0;
    lastSavedPosition.value = 0;
    const track = playerState.tracks[index];
    audio.src = `/api/v1/items/${encodeURIComponent(track.id)}/stream`;
    audio.load();

    if ("mediaSession" in navigator) {
      const filename = track.relativePath.split("/").at(-1) ?? "";
      const stem = filename.replace(/\.[^.]+$/, "");
      const parts = stem.split(" - ");
      const artist = parts.length >= 3 ? parts[0] : "";
      const album = parts.length >= 2 ? parts[parts.length - 2] : "";
      const title = parts.length >= 2 ? parts[parts.length - 1] : stem;
      navigator.mediaSession.metadata = new MediaMetadata({
        title,
        artist,
        album,
        artwork: [
          {
            src: `/api/v1/items/${encodeURIComponent(track.id)}/image`,
            sizes: "512x512",
            type: "image/png",
          },
        ],
      });
    }

    loadPlaybackPosition(track);
    audio.play().catch(() => {});
  });

  const togglePlay = $(() => {
    const audio = audioRef.value;
    if (!audio) return;
    if (audio.paused) {
      audio.play().catch(() => {});
    } else {
      audio.pause();
    }
  });

  const skipNext = $(() => {
    if (playerState.tracks.length === 0) return;
    const nextIndex = resolveNextIndex(playerState.currentIndex);
    playTrack(nextIndex);
  });

  const skipPrev = $(() => {
    if (playerState.tracks.length === 0) return;
    const prevIndex = resolvePrevIndex(playerState.currentIndex);
    playTrack(prevIndex);
  });

  const setVolume = $((value: number) => {
    playerState.volume = value;
    const audio = audioRef.value;
    if (audio) audio.volume = value;
  });

  const seek = $((time: number) => {
    const audio = audioRef.value;
    if (audio) audio.currentTime = time;
  });

  const playAllTracks = $(() => {
    if (playerState.tracks.length === 0) return;
    playerState.albumView = false;
    playerState.selectedAlbumDir = "";
    if (playerState.shuffle && playerState.shuffledIndices.length > 0) {
      playTrack(playerState.shuffledIndices[0]);
    } else {
      playTrack(0);
    }
  });

  const playAlbum = $((albumDir: string) => {
    playerState.selectedAlbumDir = albumDir;
    playerState.albumView = false;
    const firstInAlbum = playerState.tracks.findIndex((t) =>
      t.relativePath.startsWith(albumDir + "/"),
    );
    if (firstInAlbum >= 0) {
      if (playerState.shuffle) buildShuffled();
      playTrack(firstInAlbum);
    }
  });

  const toggleShuffle = $(() => {
    playerState.shuffle = !playerState.shuffle;
    if (playerState.shuffle) {
      buildShuffled();
    }
  });

  const cycleLoop = $(() => {
    const modes: Array<"off" | "one" | "all"> = ["off", "one", "all"];
    const idx = modes.indexOf(playerState.loop);
    playerState.loop = modes[(idx + 1) % modes.length];
  });

  const cycleSleepTimer = $(() => {
    const durations = [0, 15, 30, 45, 60];
    const idx = durations.indexOf(playerState.sleepTimer);
    playerState.sleepTimer = durations[(idx + 1) % durations.length];
    if (playerState.sleepTimer > 0) {
      playerState.sleepRemaining = playerState.sleepTimer * 60;
    } else {
      playerState.sleepRemaining = 0;
    }
  });

  useVisibleTask$(({ cleanup }) => {
    const audio = audioRef.value;
    if (!audio) return;

    const onPlay = () => {
      playerState.isPlaying = true;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "playing";
      }
      startSaveTimer();
    };
    const onPause = () => {
      playerState.isPlaying = false;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "paused";
      }
      savePlaybackPosition();
      stopSaveTimer();
    };
    const onTimeUpdate = () => {
      playerState.currentTime = audio.currentTime;
    };
    const onDurationChange = () => {
      playerState.duration = audio.duration || 0;
    };
    const onEnded = () => {
      savePlaybackPosition();
      if (playerState.loop === "one") {
        audio.currentTime = 0;
        audio.play().catch(() => {});
        return;
      }
      if (playerState.loop !== "all" && playerState.tracks.length > 0) {
        const nextIndex = resolveNextIndex(playerState.currentIndex);
        const n = playerState.tracks.length;
        const shuffled =
          playerState.shuffle && playerState.shuffledIndices.length === n;
        const isLast = shuffled
          ? playerState.shuffledIndices.indexOf(playerState.currentIndex) ===
            n - 1
          : playerState.currentIndex === n - 1;
        if (isLast) {
          playerState.isPlaying = false;
          if ("mediaSession" in navigator) {
            navigator.mediaSession.playbackState = "paused";
          }
          return;
        }
        playTrack(nextIndex);
        return;
      }
      playTrack(resolveNextIndex(playerState.currentIndex));
    };
    const onVolumeChange = () => {
      playerState.volume = audio.volume;
    };
    const onError = () => {
      playerState.isPlaying = false;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "none";
      }
    };

    audio.addEventListener("play", onPlay);
    audio.addEventListener("pause", onPause);
    audio.addEventListener("timeupdate", onTimeUpdate);
    audio.addEventListener("durationchange", onDurationChange);
    audio.addEventListener("ended", onEnded);
    audio.addEventListener("volumechange", onVolumeChange);
    audio.addEventListener("error", onError);

    if ("mediaSession" in navigator) {
      navigator.mediaSession.setActionHandler("play", () => togglePlay());
      navigator.mediaSession.setActionHandler("pause", () => togglePlay());
      navigator.mediaSession.setActionHandler("previoustrack", () =>
        skipPrev(),
      );
      navigator.mediaSession.setActionHandler("nexttrack", () => skipNext());
      navigator.mediaSession.setActionHandler("seekto", (details) => {
        if (details.seekTime != null) seek(details.seekTime);
      });
    }

    const sleepInterval = setInterval(() => {
      if (
        playerState.sleepTimer > 0 &&
        playerState.sleepRemaining > 0 &&
        playerState.isPlaying
      ) {
        playerState.sleepRemaining -= 1;
        if (playerState.sleepRemaining <= 0) {
          playerState.sleepTimer = 0;
          const a = audioRef.value;
          if (a) a.pause();
        }
      }
    }, 1000);

    cleanup(() => {
      audio.removeEventListener("play", onPlay);
      audio.removeEventListener("pause", onPause);
      audio.removeEventListener("timeupdate", onTimeUpdate);
      audio.removeEventListener("durationchange", onDurationChange);
      audio.removeEventListener("ended", onEnded);
      audio.removeEventListener("volumechange", onVolumeChange);
      audio.removeEventListener("error", onError);
      stopSaveTimer();
      clearInterval(sleepInterval);
    });
  });

  const currentTrack = playerState.tracks[playerState.currentIndex];
  const currentFilename = currentTrack
    ? (currentTrack.relativePath.split("/").at(-1) ?? "")
    : "";
  const currentStem = currentFilename.replace(/\.[^.]+$/, "");

  const formatTime = (seconds: number): string => {
    if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  };

  const albums = (() => {
    const dirMap = new Map<
      string,
      { name: string; tracks: CatalogItem[]; artworkTrackId: string }
    >();
    for (const track of playerState.tracks) {
      const parts = track.relativePath.split("/");
      parts.pop();
      const dirPath = parts.join("/");
      const dirName = parts.at(-1) ?? "";
      if (!dirMap.has(dirPath)) {
        dirMap.set(dirPath, {
          name: dirName,
          tracks: [],
          artworkTrackId: track.id,
        });
      }
      dirMap.get(dirPath)!.tracks.push(track);
    }
    return Array.from(dirMap.entries()).map(([dirPath, album]) => ({
      dirPath,
      ...album,
    }));
  })();

  const visibleTracks =
    playerState.selectedAlbumDir && !playerState.albumView
      ? playerState.tracks.filter((t) =>
          t.relativePath.startsWith(playerState.selectedAlbumDir + "/"),
        )
      : playerState.tracks;

  const sleepLabel = (() => {
    if (playerState.sleepTimer === 0) return "";
    return formatTime(playerState.sleepRemaining);
  })();

  return (
    <section class="player-layout">
      <div class="player-main">
        <div class="now-playing">
          {currentTrack ? (
            <div class="now-playing-artwork">
              <img
                src={`/api/v1/items/${encodeURIComponent(currentTrack.id)}/image`}
                alt=""
                loading="lazy"
                class="album-art"
              />
            </div>
          ) : (
            <div class="now-playing-artwork empty-art">
              <Icon name="play" size={64} />
            </div>
          )}
          <div class="now-playing-info">
            <h2 class="track-title">
              {currentTrack
                ? (currentStem.split(" - ").at(-1) ?? currentStem)
                : "No track selected"}
            </h2>
            {currentTrack && (
              <p class="track-artist-album">
                {currentStem.split(" - ").slice(0, -1).join(" - ") ||
                  currentTrack.rootId
                    .split("-")
                    .at(-1)
                    ?.replace(/^\w/, (c: string) => c.toUpperCase())}
              </p>
            )}
          </div>
          <div class="player-time">
            <span>{formatTime(playerState.currentTime)}</span>
            <div class="seek-bar-container">
              <input
                type="range"
                class="seek-bar"
                min="0"
                max={playerState.duration || 0}
                step="0.1"
                value={playerState.currentTime}
                onInput$={(_, el) => seek(Number(el.value))}
              />
            </div>
            <span>{formatTime(playerState.duration)}</span>
          </div>
          <div class="player-controls">
            <button
              type="button"
              class={{
                "control-button": true,
                "control-active": playerState.loop !== "off",
              }}
              aria-label={(() => {
                switch (playerState.loop) {
                  case "one":
                    return "Loop one";
                  case "all":
                    return "Loop all";
                  default:
                    return "Loop off";
                }
              })()}
              onClick$={cycleLoop}
            >
              {playerState.loop === "one" ? (
                <Icon name="repeat-one" size={16} />
              ) : (
                <Icon name="repeat" size={16} />
              )}
              {playerState.loop === "one" && <span class="loop-badge">1</span>}
            </button>
            <button
              type="button"
              class="control-button"
              aria-label="Previous track"
              disabled={playerState.tracks.length === 0}
              onClick$={skipPrev}
            >
              <Icon name="skip-back" size={22} />
            </button>
            <button
              type="button"
              class="control-button play-button"
              aria-label={playerState.isPlaying ? "Pause" : "Play"}
              disabled={playerState.tracks.length === 0}
              onClick$={togglePlay}
            >
              {playerState.isPlaying ? (
                <Icon name="pause" size={28} />
              ) : (
                <Icon name="play" size={28} />
              )}
            </button>
            <button
              type="button"
              class="control-button"
              aria-label="Next track"
              disabled={playerState.tracks.length === 0}
              onClick$={skipNext}
            >
              <Icon name="skip-forward" size={22} />
            </button>
            <button
              type="button"
              class={{
                "control-button": true,
                "control-active": playerState.shuffle,
              }}
              aria-label={playerState.shuffle ? "Shuffle on" : "Shuffle off"}
              onClick$={toggleShuffle}
            >
              <Icon name="shuffle" size={16} />
            </button>
          </div>
          <div class="player-extras">
            <div class="volume-control">
              <Icon name="volume" size={16} />
              <input
                type="range"
                class="volume-bar"
                min="0"
                max="1"
                step="0.01"
                value={playerState.volume}
                onInput$={(_, el) => setVolume(Number(el.value))}
              />
            </div>
            <button
              type="button"
              class={{
                "control-button": true,
                timer: true,
                "sleep-active": playerState.sleepTimer > 0,
              }}
              aria-label={
                playerState.sleepTimer > 0
                  ? `Sleep timer: ${playerState.sleepTimer} min`
                  : "Sleep timer off"
              }
              onClick$={cycleSleepTimer}
            >
              <Icon name="timer" size={16} />
              {playerState.sleepTimer > 0 && (
                <span class="sleep-label">{sleepLabel}</span>
              )}
            </button>
          </div>
        </div>
        <audio ref={audioRef} preload="auto" style="display: none;" />
      </div>
      <div class="player-sidebar">
        <div class="player-sidebar-header">
          {!playerState.albumView && (
            <button
              type="button"
              class="back-button"
              aria-label="Back to albums"
              onClick$={() => {
                playerState.albumView = true;
                playerState.selectedAlbumDir = "";
              }}
            >
              <Icon name="chevron-down" size={16} />
              Albums
            </button>
          )}
          {playerState.albumView && <h3>Albums</h3>}
          <div class="sidebar-header-actions">
            {musicRoots.length > 1 && (
              <select
                class="root-filter-select"
                value={playerState.selectedRootFilter}
                onChange$={(_, el) => {
                  playerState.selectedRootFilter = el.value;
                  playerState.albumView = true;
                  playerState.selectedAlbumDir = "";
                  loadTracks(el.value || undefined);
                }}
              >
                <option value="">All music</option>
                {musicRoots.map((root) => (
                  <option value={root.id} key={root.id}>
                    {root.label}
                  </option>
                ))}
              </select>
            )}
            {playerState.selectedAlbumDir ? (
              <button
                type="button"
                class="secondary-button compact-action"
                onClick$={() => playAlbum(playerState.selectedAlbumDir)}
              >
                <Icon name="play" size={14} /> Play album
              </button>
            ) : (
              <button
                type="button"
                class="secondary-button compact-action"
                disabled={playerState.tracks.length === 0}
                onClick$={playAllTracks}
              >
                <Icon name="play" size={14} /> Play all
              </button>
            )}
          </div>
        </div>
        {playerState.loading ? (
          <LoadingState />
        ) : playerState.error ? (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{playerState.error}</span>
          </div>
        ) : playerState.tracks.length === 0 ? (
          <EmptyState
            title="No music found"
            detail="Add music files to your personal or shared music folders to see them here."
          />
        ) : playerState.albumView ? (
          <ul class="album-grid">
            {albums.map((album) => {
              const isCurrentAlbum =
                currentTrack &&
                currentTrack.relativePath.startsWith(album.dirPath + "/");
              return (
                <li key={album.dirPath} class="album-item">
                  <button
                    type="button"
                    class="album-button"
                    onClick$={() => playAlbum(album.dirPath)}
                  >
                    <div
                      class={{
                        "album-artwork": true,
                        "album-active": isCurrentAlbum,
                      }}
                    >
                      <img
                        src={`/api/v1/items/${encodeURIComponent(album.artworkTrackId)}/image`}
                        alt=""
                        loading="lazy"
                      />
                    </div>
                    <span class="album-name">{album.name}</span>
                    <span class="album-count">
                      {album.tracks.length}{" "}
                      {album.tracks.length === 1 ? "track" : "tracks"}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        ) : (
          <ul class="track-list">
            {visibleTracks.map((track) => {
              const filename = track.relativePath.split("/").at(-1) ?? "";
              const stem = filename.replace(/\.[^.]+$/, "");
              const dirPath = track.relativePath
                .split("/")
                .slice(0, -1)
                .join("/");
              const isActive =
                playerState.tracks.indexOf(track) === playerState.currentIndex;
              return (
                <li
                  key={track.id}
                  class={{ "track-item": true, active: isActive }}
                >
                  <button
                    type="button"
                    class="track-button"
                    onClick$={() =>
                      playTrack(playerState.tracks.indexOf(track))
                    }
                  >
                    <div class="track-artwork-thumb">
                      <img
                        src={`/api/v1/items/${encodeURIComponent(track.id)}/image`}
                        alt=""
                        loading="lazy"
                      />
                    </div>
                    <div class="track-info">
                      <span class="track-name">
                        {stem.split(" - ").at(-1) ?? stem}
                      </span>
                      <span class="track-album">
                        {stem.split(" - ").slice(0, -1).join(" - ") || dirPath}
                      </span>
                    </div>
                    {isActive && playerState.isPlaying && (
                      <span class="playing-indicator" aria-hidden="true">
                        <span class="bar" />
                        <span class="bar" />
                        <span class="bar" />
                      </span>
                    )}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>
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
