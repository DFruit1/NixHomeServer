import {
  $,
  component$,
  type QRL,
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
  | "metadata"
  | "refresh";

const VIEWS = new Set<View>([
  "overview",
  "library",
  "conversions",
  "subtitles",
  "metadata",
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

interface CatalogItem {
  id: string;
  rootId: string;
  relativePath: string;
  mediaKind: string;
  sizeBytes: number;
  modifiedNs: number;
}

interface Conversion {
  title?: string;
  mediaKind?: string;
  percent?: number;
  detail?: string;
}

interface ConversionEnvelope {
  available: boolean;
  progress: {
    state?: string;
    conversions?: Conversion[];
  };
}

interface InboxIso {
  name: string;
  volumeId?: string | null;
  sizeBytes: number;
  modifiedNs: number;
}

interface ConversionInbox {
  available: boolean;
  pending: InboxIso[];
  processed: InboxIso[];
  failed: InboxIso[];
}

interface DashboardState {
  status?: Status;
  session?: Session;
  roots: MediaRoot[];
  items: CatalogItem[];
  conversions?: ConversionEnvelope;
  selectedRootId: string;
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
  { id: "metadata", label: "Metadata", icon: "tag" },
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
  const state = useStore<DashboardState>({
    roots: [],
    items: [],
    selectedRootId: "",
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
      if (selectedRoot && view.value === "library") {
        const result = await api<{ items: CatalogItem[] }>(
          `/items?rootId=${encodeURIComponent(selectedRoot.id)}`,
        );
        state.items = result.items;
      }
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });

  const loadItems = $(async (rootId: string) => {
    state.selectedRootId = rootId;
    state.error = "";
    try {
      const result = await api<{ items: CatalogItem[] }>(
        `/items?rootId=${encodeURIComponent(rootId)}`,
      );
      state.items = result.items;
    } catch (error) {
      state.error = readableError(error);
    }
  });

  const selectItem = $((item: CatalogItem) => {
    state.selectedItemId = item.id;
    const category = state.roots.find(
      (root) => root.id === item.rootId,
    )?.category;
    state.editProfile = profileForCategory(category);
    const filename = item.relativePath.split("/").at(-1) ?? item.relativePath;
    state.editTitle = filename
      .replace(/\.[A-Za-z0-9]+$/, "")
      .replace(/ \([0-9]{4}\)$/, "");
    state.editYear = filename.match(/ \(([0-9]{4})\)(?:\.[^.]+)?$/)?.[1] ?? "";
    state.editCreator = "";
    state.editCollection = "";
    state.editSeason =
      filename.match(/[Ss]([0-9]{1,3})[Ee][0-9]{1,4}/)?.[1] ?? "";
    state.editEpisode =
      filename.match(/[Ss][0-9]{1,3}[Ee]([0-9]{1,4})/)?.[1] ?? "";
    state.editEpisodeTitle = "";
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
    <div class="app-shell">
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
          <div class="avatar" aria-hidden="true">
            {(state.session?.username ?? "?").slice(0, 1).toUpperCase()}
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
        <header class="topbar">
          <h1>{NAV_ITEMS.find((item) => item.id === view.value)?.label}</h1>
        </header>

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
          <section class="page-grid overview" aria-label="Server overview">
            <section class="panel wide-panel">
              <div class="panel-heading">
                <div>
                  <h3>Registered media roots</h3>
                </div>
                <a class="text-button" href="?view=library">
                  Browse libraries <Icon name="arrow" size={17} />
                </a>
              </div>
              <div class="root-list compact">
                {state.roots.slice(0, 5).map((root) => (
                  <RootRow root={root} key={root.id} />
                ))}
              </div>
            </section>
            <section class="panel activity-panel">
              <div class="panel-heading">
                <div>
                  <h3>DVD ISO queue</h3>
                </div>
                <span
                  class={{
                    "status-badge": true,
                    live: currentConversions.length > 0,
                  }}
                >
                  {currentConversions.length > 0 ? "Working" : "Idle"}
                </span>
              </div>
              <ConversionList
                conversions={currentConversions}
                available={state.conversions?.available ?? false}
              />
            </section>
          </section>
        ) : view.value === "library" ? (
          <LibraryView
            state={state}
            selectItem$={selectItem}
            previewRename$={previewRename}
            confirmRename$={confirmRename}
          />
        ) : view.value === "conversions" ? (
          <ConversionsView initial={state.conversions} />
        ) : view.value === "subtitles" ? (
          <SubtitleView
            roots={state.roots}
            session={state.session}
            status={state.status}
          />
        ) : view.value === "metadata" ? (
          <MetadataView
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

const RootRow = component$<{
  root: MediaRoot;
}>((props) => (
  <a
    class="root-row"
    href={`?view=library&root=${encodeURIComponent(props.root.id)}`}
  >
    <span class="root-icon">
      <Icon name="folder" size={19} />
    </span>
    <span class="root-name">
      <strong>{rootDisplayName(props.root)}</strong>
      <small>
        {props.root.scope} · {props.root.category}
      </small>
    </span>
    <span
      class={{ "availability-dot": true, available: props.root.available }}
    />
    <Icon name="arrow" size={17} />
  </a>
));

function rootDisplayName(root: MediaRoot): string {
  return root.category
    ? root.category.charAt(0).toUpperCase() + root.category.slice(1)
    : root.label;
}

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
    inside.find((item) => item.mediaKind === "artwork")?.id ??
    inside[0]?.id ??
    ""
  );
}

const MediaImage = component$<{
  imageId: string;
  title: string;
  subtitle: string;
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
        <figcaption>
          <strong>{props.title}</strong>
          {props.subtitle && <small>{props.subtitle}</small>}
        </figcaption>
      </figure>
    );
  },
);

const RootChoice = component$<{
  root: MediaRoot;
  selectedRootId: string;
}>((props) => (
  <a
    class={{
      "root-choice": true,
      selected: props.root.id === props.selectedRootId,
    }}
    href={`?view=library&root=${encodeURIComponent(props.root.id)}`}
    aria-current={props.root.id === props.selectedRootId ? "true" : undefined}
  >
    <Icon name="folder" size={18} />
    <span>
      <strong>{rootDisplayName(props.root)}</strong>
    </span>
    <span
      class={{ "availability-dot": true, available: props.root.available }}
    />
  </a>
));

const LibraryView = component$<{
  state: DashboardState;
  selectItem$: QRL<(item: CatalogItem) => void>;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
}>((props) => {
  const browser = useStore({
    expanded: {} as Record<string, boolean>,
    folderFilter: "",
    selectedFolder: "",
  });
  const selectFolder$ = $((path: string) => {
    browser.selectedFolder = path;
    props.state.selectedItemId = "";
    props.state.preview = undefined;
  });
  const selected = props.state.roots.find(
    (root) => root.id === props.state.selectedRootId,
  );
  const libraryRoots = props.state.roots.filter(
    (root) => root.category !== "iso",
  );
  const sharedRoots = libraryRoots.filter((root) => root.scope === "shared");
  const personalRoots = libraryRoots.filter(
    (root) => root.scope === "personal",
  );
  const folders = topLevelFolders(props.state.items);
  const visibleItems = browser.folderFilter
    ? props.state.items.filter((item) =>
        item.relativePath.startsWith(`${browser.folderFilter}/`),
      )
    : props.state.items;
  const tree = buildTree(visibleItems);
  const selectedItem = props.state.items.find(
    (item) => item.id === props.state.selectedItemId,
  );
  const imageTitle =
    selectedItem?.relativePath.split("/").at(-1) ??
    (browser.selectedFolder
      ? folderDisplayName(browser.selectedFolder.split("/").at(-1) ?? "")
      : "");
  const imageSubtitle = selectedItem
    ? selectedItem.relativePath
    : browser.selectedFolder;
  return (
    <section class="library-layout">
      <aside class="panel root-picker">
        <div class="panel-heading">
          <div>
            <h3>Media roots</h3>
          </div>
        </div>
        <div class="root-list grouped">
          {sharedRoots.length > 0 && (
            <div class="root-group">
              <h4 class="root-group-heading">Shared</h4>
              {sharedRoots.map((root) => (
                <RootChoice
                  root={root}
                  selectedRootId={props.state.selectedRootId}
                  key={root.id}
                />
              ))}
            </div>
          )}
          {personalRoots.length > 0 && (
            <div class="root-group">
              <h4 class="root-group-heading">Personal</h4>
              {personalRoots.map((root) => (
                <RootChoice
                  root={root}
                  selectedRootId={props.state.selectedRootId}
                  key={root.id}
                />
              ))}
            </div>
          )}
        </div>
        {(selectedItem || browser.selectedFolder) && (
          <div class="root-picker-image">
            <MediaImage
              imageId={artworkCandidateId(
                props.state.items,
                props.state.selectedItemId,
                browser.selectedFolder,
              )}
              title={imageTitle}
              subtitle={imageSubtitle}
            />
          </div>
        )}
      </aside>
      <section class="panel catalog-panel">
        <div class="panel-heading catalog-heading">
          <div>
            <h3>
              {selected
                ? `${rootDisplayName(selected)} (${selected.scope})`
                : "Choose a root"}
            </h3>
          </div>
        </div>
        {!selected ? (
          <EmptyState
            title="Choose a media root"
            detail="Select a registered location to inspect its catalog."
          />
        ) : props.state.items.length === 0 ? (
          <EmptyState
            title="No supported media files found"
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
                      active: browser.folderFilter === folder,
                    }}
                    type="button"
                    key={folder}
                    aria-pressed={browser.folderFilter === folder}
                    onClick$={() => {
                      browser.folderFilter =
                        browser.folderFilter === folder ? "" : folder;
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
              aria-label={`${selected.label} items`}
            >
              {tree.map((node) => (
                <TreeBranch
                  node={node}
                  depth={0}
                  browser={browser}
                  selectedItemId={props.state.selectedItemId}
                  selectedFolder={browser.selectedFolder}
                  selectItem$={props.selectItem$}
                  selectFolder$={selectFolder$}
                  key={node.path}
                />
              ))}
            </div>
          </>
        )}
        {props.state.session?.canEdit && props.state.selectedItemId && (
          <div class="rename-workflow">
            <div class="rename-heading">
              <div>
                <h4>Preview a convention-aware path</h4>
              </div>
              <button
                class="close-button"
                type="button"
                aria-label="Close rename editor"
                onClick$={() => {
                  props.state.selectedItemId = "";
                  props.state.preview = undefined;
                }}
              >
                ×
              </button>
            </div>
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
                  {profilesForCategory(selected?.category).map((profile) => (
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
                Folder names are constructed from these fields. Unknown years
                stay omitted; no destination path is accepted from the browser.
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
            {props.state.preview && (
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
                    <Icon name="alert" size={16} />
                    {warning}
                  </p>
                ))}
                <div class="plan-actions">
                  <span>
                    Preview expires in 30 minutes and is bound to the current
                    file fingerprint.
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
            )}
          </div>
        )}
      </section>
    </section>
  );
});

const TreeBranch = component$<{
  node: TreeNode;
  depth: number;
  browser: {
    expanded: Record<string, boolean>;
    selectedFolder: string;
    folderFilter: string;
  };
  selectedItemId: string;
  selectedFolder: string;
  selectItem$: QRL<(item: CatalogItem) => void>;
  selectFolder$: QRL<(path: string) => void>;
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
  return (
    <div class="tree-branch" role="treeitem" aria-expanded={expanded}>
      <button
        class={{
          "tree-row": true,
          folder: true,
          selected: props.selectedFolder === node.path,
        }}
        style={{ paddingLeft: `${14 + props.depth * 16}px` }}
        type="button"
        onClick$={() => {
          props.browser.expanded[node.path] = !expanded;
          props.selectFolder$(node.path);
        }}
      >
        <Icon name={expanded ? "chevron-down" : "chevron-right"} size={15} />
        <span class="tree-name">{node.name}</span>
      </button>
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
              key={child.path}
            />
          ))}
        </div>
      )}
    </div>
  );
});

const ConversionList = component$<{
  conversions: Conversion[];
  available: boolean;
  expanded?: boolean;
}>((props) => {
  if (props.conversions.length === 0) {
    return (
      <EmptyState
        title={
          props.available
            ? "No conversion in progress"
            : "MKVMaker is unavailable"
        }
        detail={
          props.available
            ? "The DVD ISO queue is currently idle."
            : "Media Manager will reconnect automatically when progress data appears."
        }
      />
    );
  }
  return (
    <div class={{ "conversion-list": true, expanded: props.expanded }}>
      {props.conversions.map((conversion, index) => {
        const percent = Math.max(0, Math.min(100, conversion.percent ?? 0));
        return (
          <article class="conversion-card" key={`${conversion.title}-${index}`}>
            <div class="disc-visual">
              <span />
              <span />
            </div>
            <div class="conversion-copy">
              <h4>{conversion.title ?? "Untitled conversion"}</h4>
              <p>{conversion.detail ?? "Encoding a Jellyfin-compatible MKV"}</p>
              <div class="progress-track" aria-label={`${percent}% complete`}>
                <span style={{ width: `${percent}%` }} />
              </div>
              <div class="progress-meta">
                <span>Converting</span>
                <strong class="tabular">{percent.toFixed(0)}%</strong>
              </div>
            </div>
          </article>
        );
      })}
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

    const current = conv.conversions?.progress.conversions ?? [];
    const working = current.length > 0;
    const inboxReady = conv.inbox?.available ?? false;
    const converterReporting = conv.conversions?.available ?? false;
    const statusLabel = working
      ? "Working"
      : inboxReady
        ? "Ready"
        : "Not set up";
    return (
      <section class="single-column conversions-layout">
        {conv.error && (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{conv.error}</span>
            <button type="button" onClick$={() => (conv.error = "")}>
              ×
            </button>
          </div>
        )}
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h3>DVD ISO converter</h3>
            </div>
            <span
              class={{
                "status-badge": true,
                live: working || (inboxReady && converterReporting),
              }}
            >
              {statusLabel}
            </span>
          </div>
          <div class="setup-body">
            {inboxReady ? (
              <p class="setup-ready">
                The converter is set up and watching the shared inbox.
                {working
                  ? " An ISO is being converted right now."
                  : " Drop an ISO in the inbox to start a conversion."}
              </p>
            ) : (
              <p class="setup-missing">
                The shared DVD ISO inbox is not available on this server. Enable
                the MKVMaker module in the server configuration and make sure
                the media-manager service can read _Shared/_ISO/_DVDs.
              </p>
            )}
            <ol class="setup-steps">
              <li>
                Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.
              </li>
              <li>
                Leave the ISO untouched for about one minute so the server picks
                it up.
              </li>
              <li>
                Finished films appear in the shared video library. Source ISOs
                move to _Processed, or to _Failed after repeated failures.
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
            conversions={current}
            available={converterReporting}
            expanded
          />
        </section>
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h3>ISO inbox</h3>
            </div>
            <span class={{ "status-badge": true, live: inboxReady }}>
              {inboxReady
                ? `${conv.inbox?.pending.length ?? 0} waiting`
                : "Unavailable"}
            </span>
          </div>
          {!conv.inbox ? (
            <p class="quiet-copy">Loading the inbox…</p>
          ) : !conv.inbox.available ? (
            <p class="quiet-copy">
              The inbox directory _Shared/_ISO/_DVDs does not exist on this
              server yet.
            </p>
          ) : (
            <div class="inbox-groups">
              <InboxGroup
                title="Waiting"
                detail="ISOs queued for conversion"
                isos={conv.inbox.pending}
                empty="No ISOs are waiting."
              />
              <InboxGroup
                title="Processed"
                detail="Source ISOs of completed conversions"
                isos={conv.inbox.processed}
                empty="Nothing has been processed yet."
              />
              <InboxGroup
                title="Failed"
                detail="ISOs that could not be converted"
                isos={conv.inbox.failed}
                empty="No failed conversions."
              />
            </div>
          )}
        </section>
      </section>
    );
  },
);

const InboxGroup = component$<{
  title: string;
  detail: string;
  isos: InboxIso[];
  empty: string;
}>((props) => (
  <section class="inbox-group">
    <header>
      <h4>{props.title}</h4>
      <small>{props.detail}</small>
    </header>
    {props.isos.length === 0 ? (
      <p class="inbox-empty">{props.empty}</p>
    ) : (
      <ul>
        {props.isos.map((iso) => (
          <li key={iso.name}>
            <span class="inbox-iso-name">
              <strong>{iso.volumeId || iso.name}</strong>
              {iso.volumeId && <small>{iso.name}</small>}
            </span>
            <span class="inbox-iso-meta">
              <span class="tabular muted">{formatBytes(iso.sizeBytes)}</span>
              <span class="muted">{formatModified(iso.modifiedNs)}</span>
            </span>
          </li>
        ))}
      </ul>
    )}
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
  hearingImpaired: boolean;
  hashMatched: boolean;
  machineTranslated: boolean;
  aiTranslated: boolean;
}

interface SubtitleState {
  rootId: string;
  items: CatalogItem[];
  itemId: string;
  language: string;
  query: string;
  hearingImpaired: boolean;
  loadingItems: boolean;
  searching: boolean;
  installing: boolean;
  confirming: boolean;
  results: SubtitleMatch[];
  preview?: MutationPreview;
  error: string;
  notice: string;
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
    loadingItems: false,
    searching: false,
    installing: false,
    confirming: false,
    results: [],
    error: "",
    notice: "",
  });

  const loadVideos = $(async (rootId: string) => {
    subtitle.rootId = rootId;
    subtitle.loadingItems = true;
    subtitle.itemId = "";
    subtitle.results = [];
    subtitle.preview = undefined;
    subtitle.error = "";
    try {
      const result = await api<{ items: CatalogItem[] }>(
        `/items?rootId=${encodeURIComponent(rootId)}`,
      );
      subtitle.items = result.items.filter(
        (item) => item.mediaKind === "video",
      );
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
    try {
      const parameters = new URLSearchParams({ languages: subtitle.language });
      if (subtitle.query.trim()) parameters.set("query", subtitle.query.trim());
      const response = await api<{
        matchMethod: "movie-hash" | "title-fallback";
        results: SubtitleMatch[];
      }>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/search?${parameters}`,
      );
      subtitle.results = response.results;
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
              disabled={subtitle.loadingItems || subtitle.items.length === 0}
              onChange$={(_, select) => {
                subtitle.itemId = select.value;
                subtitle.results = [];
                subtitle.preview = undefined;
              }}
            >
              <option value="">
                {subtitle.loadingItems
                  ? "Loading videos…"
                  : subtitle.items.length === 0
                    ? "No supported videos found in this library"
                    : "Choose a video…"}
              </option>
              {subtitle.items.map((item) => (
                <option value={item.id} key={item.id}>
                  {item.relativePath}
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
                    Create an OpenSubtitles.com account and application API key.
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
                    {match.hashMatched ? " · exact file match" : ""}
                    {match.hearingImpaired ? " · SDH" : ""}
                    {match.machineTranslated || match.aiTranslated
                      ? " · machine translated"
                      : ""}
                  </span>
                </div>
                <button
                  class="secondary-button"
                  type="button"
                  disabled={subtitle.installing}
                  onClick$={() => selectProviderSubtitle(match)}
                >
                  Preview
                </button>
              </article>
            ))}
            {subtitle.results.length === 0 && (
              <p class="quiet-copy">
                Search results will show release names, language, accessibility,
                and translation flags so an editor can choose the closest match.
              </p>
            )}
          </div>
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

interface MetadataState {
  rootId: string;
  items: CatalogItem[];
  itemId: string;
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
  loadingItems: boolean;
  planning: boolean;
  confirming: boolean;
  preview?: MutationPreview;
  error: string;
  notice: string;
}

const MetadataView = component$<{
  roots: MediaRoot[];
  session?: Session;
  status?: Status;
}>((props) => {
  const mediaRoots = props.roots.filter((root) => root.category !== "iso");
  const metadata = useStore<MetadataState>({
    rootId: mediaRoots[0]?.id ?? "",
    items: [],
    itemId: "",
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
    loadingItems: false,
    planning: false,
    confirming: false,
    error: "",
    notice: "",
  });

  const loadMetadataItems = $(async (rootId: string) => {
    metadata.rootId = rootId;
    metadata.loadingItems = true;
    metadata.itemId = "";
    metadata.preview = undefined;
    metadata.error = "";
    try {
      const result = await api<{ items: CatalogItem[] }>(
        `/items?rootId=${encodeURIComponent(rootId)}`,
      );
      metadata.items = result.items.filter((item) =>
        ["video", "music", "audiobook", "book"].includes(item.mediaKind),
      );
    } catch (error) {
      metadata.error = readableError(error);
    } finally {
      metadata.loadingItems = false;
    }
  });

  useVisibleTask$(async () => {
    if (metadata.rootId) await loadMetadataItems(metadata.rootId);
  });

  const chooseMetadataItem = $((itemId: string) => {
    metadata.itemId = itemId;
    metadata.preview = undefined;
    const item = metadata.items.find((candidate) => candidate.id === itemId);
    if (!item) return;
    const filename = item.relativePath.split("/").at(-1) ?? item.relativePath;
    metadata.title = filename
      .replace(/\.[A-Za-z0-9]+$/, "")
      .replace(/ \([0-9]{4}\)$/, "");
    metadata.year = filename.match(/ \(([0-9]{4})\)/)?.[1] ?? "";
  });

  const previewMetadata = $(async () => {
    if (!metadata.itemId || !metadata.title.trim() || metadata.planning) return;
    metadata.planning = true;
    metadata.error = "";
    metadata.notice = "";
    const fields: Record<string, unknown> = {
      title: metadata.title.trim(),
      authors: commaSeparated(metadata.authors),
      narrators: commaSeparated(metadata.narrators),
      genres: commaSeparated(metadata.genres),
    };
    const optional: Array<[string, string]> = [
      ["series", metadata.series],
      ["volumeNumber", metadata.volumeNumber],
      ["publisher", metadata.publisher],
      ["isbn", metadata.isbn],
      ["language", metadata.language],
      ["description", metadata.description],
    ];
    for (const [key, value] of optional) {
      if (value.trim()) fields[key] = value.trim();
    }
    if (metadata.year.trim()) fields.year = Number.parseInt(metadata.year, 10);
    try {
      metadata.preview = await api<MutationPreview>(
        `/items/${encodeURIComponent(metadata.itemId)}/metadata/sidecar`,
        { method: "POST", body: JSON.stringify(fields) },
      );
    } catch (error) {
      metadata.error = readableError(error);
    } finally {
      metadata.planning = false;
    }
  });

  const confirmMetadata = $(async () => {
    if (!metadata.preview || metadata.confirming) return;
    metadata.confirming = true;
    metadata.error = "";
    try {
      await api(`/plans/${encodeURIComponent(metadata.preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${metadata.preview.digest}"` },
      });
      metadata.notice =
        "The metadata sidecar was added to the global mutation queue.";
      metadata.preview = undefined;
    } catch (error) {
      metadata.error = readableError(error);
    } finally {
      metadata.confirming = false;
    }
  });

  const selectedMetadataItem = metadata.items.find(
    (item) => item.id === metadata.itemId,
  );
  return (
    <section class="metadata-layout">
      {metadata.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{metadata.error}</span>
          <button type="button" onClick$={() => (metadata.error = "")}>
            ×
          </button>
        </div>
      )}
      {metadata.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{metadata.notice}</span>
        </div>
      )}
      <div class="metadata-columns">
        <section class="panel metadata-panel">
          <div class="panel-heading">
            <div>
              <h3>Metadata fields</h3>
            </div>
            <span
              class={{ "status-badge": true, live: props.session?.canEdit }}
            >
              {props.session?.canEdit ? "Editor" : "Viewer"}
            </span>
          </div>
          <div class="metadata-form">
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
                  (metadata.year = input.value.replace(/\D/g, "").slice(0, 4))
                }
              />
            </label>
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
                onInput$={(_, input) => (metadata.volumeNumber = input.value)}
              />
            </label>
            <label>
              <span>Publisher / studio</span>
              <input
                value={metadata.publisher}
                onInput$={(_, input) => (metadata.publisher = input.value)}
              />
            </label>
            <label>
              <span>ISBN</span>
              <input
                value={metadata.isbn}
                onInput$={(_, input) => (metadata.isbn = input.value)}
              />
            </label>
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
            <label class="description-input">
              <span>Description</span>
              <textarea
                value={metadata.description}
                maxLength={20000}
                rows={5}
                onInput$={(_, input) => (metadata.description = input.value)}
              />
            </label>
          </div>
          <div class="metadata-actions">
            <span>
              NFO is used for video/music; OPF is used for books and audiobooks.
            </span>
            <button
              class="primary-button"
              type="button"
              disabled={
                !props.session?.canEdit ||
                !metadata.itemId ||
                !metadata.title.trim() ||
                metadata.planning
              }
              onClick$={previewMetadata}
            >
              <Icon name="scan" size={18} />
              {metadata.planning ? "Preparing…" : "Preview metadata sidecar"}
            </button>
          </div>
        </section>
        <div class="metadata-side">
          {selectedMetadataItem && (
            <MediaImage
              imageId={selectedMetadataItem.id}
              title={
                selectedMetadataItem.relativePath.split("/").at(-1) ??
                selectedMetadataItem.relativePath
              }
              subtitle={selectedMetadataItem.relativePath}
            />
          )}
          <section class="panel metadata-destination">
            <div class="panel-heading">
              <div>
                <h3>Metadata destination</h3>
              </div>
            </div>
            <div class="metadata-picker">
              <label>
                <span>Library</span>
                <select
                  value={metadata.rootId}
                  onChange$={(_, select) => loadMetadataItems(select.value)}
                >
                  {mediaRoots.map((root) => (
                    <option value={root.id} key={root.id}>
                      {root.label}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>Media item</span>
                <select
                  value={metadata.itemId}
                  disabled={
                    metadata.loadingItems || metadata.items.length === 0
                  }
                  onChange$={(_, select) => chooseMetadataItem(select.value)}
                >
                  <option value="">
                    {metadata.loadingItems
                      ? "Loading media…"
                      : metadata.items.length === 0
                        ? "No supported media found in this library"
                        : "Choose an item…"}
                  </option>
                  {metadata.items.map((item) => (
                    <option value={item.id} key={item.id}>
                      {item.relativePath}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          </section>
        </div>
      </div>
      {metadata.preview && (
        <section class="panel metadata-preview">
          <div class="panel-heading">
            <div>
              <h3>{metadata.preview.actions[0]?.destinationRelativePath}</h3>
            </div>
          </div>
          <div class="subtitle-preview-body">
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
                  props.status?.mutationMode !== "enabled" ||
                  metadata.confirming
                }
                onClick$={confirmMetadata}
              >
                <Icon name="check" size={18} />
                {metadata.confirming ? "Queuing…" : "Confirm metadata"}
              </button>
            </div>
          </div>
        </section>
      )}
    </section>
  );
});

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
