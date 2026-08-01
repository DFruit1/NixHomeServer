import {
  $,
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError } from "./api";

type View =
  | "overview"
  | "library"
  | "conversions"
  | "subtitles"
  | "metadata"
  | "refresh";

interface Integration {
  id: string;
  label: string;
  available: boolean;
  capabilities: string[];
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

interface DashboardState {
  status?: Status;
  session?: Session;
  roots: MediaRoot[];
  items: CatalogItem[];
  conversions?: ConversionEnvelope;
  selectedRootId: string;
  loading: boolean;
  scanning: boolean;
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
  | "arrow";

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

export default component$(() => {
  const view = useSignal<View>("overview");
  const state = useStore<DashboardState>({
    roots: [],
    items: [],
    selectedRootId: "",
    loading: true,
    scanning: false,
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

  useVisibleTask$(async () => {
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
      state.selectedRootId = roots[0]?.id ?? "";
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

  const scanRoot = $(async () => {
    if (!state.selectedRootId || state.scanning) return;
    state.scanning = true;
    state.error = "";
    state.notice = "";
    try {
      const result = await api<{
        result: { itemsIndexed: number; itemsRemoved: number };
      }>("/scans", {
        method: "POST",
        body: JSON.stringify({ rootId: state.selectedRootId }),
      });
      state.notice = `Scan complete: ${result.result.itemsIndexed} indexed, ${result.result.itemsRemoved} removed.`;
      await loadItems(state.selectedRootId);
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.scanning = false;
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
  const availableIntegrations =
    state.status?.integrations.filter((item) => item.available).length ?? 0;
  const availableRoots = state.roots.filter((root) => root.available).length;

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
            <button
              key={item.id}
              type="button"
              class={{ "nav-item": true, active: view.value === item.id }}
              aria-current={view.value === item.id ? "page" : undefined}
              onClick$={() => (view.value = item.id)}
            >
              <Icon name={item.icon} />
              <span>{item.label}</span>
            </button>
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
          <div>
            <span class="eyebrow">Sydney Basiniot Media Server</span>
            <h1>{NAV_ITEMS.find((item) => item.id === view.value)?.label}</h1>
          </div>
          <div class="mode-pill">
            <Icon name="shield" size={18} />
            {state.status?.mutationMode === "enabled"
              ? "Staged changes enabled"
              : "Read-only safety mode"}
          </div>
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
            <div class="intro-copy">
              <span class="section-label">At a glance</span>
              <h2>Your media, organized without touching the filesystem.</h2>
              <p>
                Review conversion activity, inspect canonical library roots, and
                preview changes through one authenticated control surface.
              </p>
            </div>
            <div class="stat-grid">
              <StatCard
                label="Available roots"
                value={availableRoots}
                detail={`${state.roots.length} registered`}
                icon="folder"
              />
              <StatCard
                label="Active conversions"
                value={currentConversions.length}
                detail={
                  state.conversions?.available
                    ? "MKVMaker connected"
                    : "MKVMaker idle or absent"
                }
                icon="disc"
              />
              <StatCard
                label="Connected apps"
                value={availableIntegrations}
                detail={`${state.status?.integrations.length ?? 0} adapters registered`}
                icon="refresh"
              />
            </div>
            <section class="panel wide-panel">
              <div class="panel-heading">
                <div>
                  <span class="section-label">Library map</span>
                  <h3>Registered media roots</h3>
                </div>
                <button
                  class="text-button"
                  type="button"
                  onClick$={() => (view.value = "library")}
                >
                  Browse libraries <Icon name="arrow" size={17} />
                </button>
              </div>
              <div class="root-list compact">
                {state.roots.slice(0, 5).map((root) => (
                  <RootRow
                    root={root}
                    key={root.id}
                    onOpen$={() => {
                      view.value = "library";
                      loadItems(root.id);
                    }}
                  />
                ))}
              </div>
            </section>
            <section class="panel activity-panel">
              <div class="panel-heading">
                <div>
                  <span class="section-label">Conversion activity</span>
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
            loadItems$={loadItems}
            scanRoot$={scanRoot}
            selectItem$={selectItem}
            previewRename$={previewRename}
            confirmRename$={confirmRename}
          />
        ) : view.value === "conversions" ? (
          <section class="single-column">
            <div class="intro-copy compact-intro">
              <span class="section-label">MKVMaker</span>
              <h2>DVD ISO conversion progress</h2>
              <p>
                Conversion reporting remains useful even when MKVMaker is
                disabled or between runs.
              </p>
            </div>
            <section class="panel">
              <ConversionList
                conversions={currentConversions}
                available={state.conversions?.available ?? false}
                expanded
              />
            </section>
          </section>
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

const StatCard = component$<{
  label: string;
  value: number;
  detail: string;
  icon: IconName;
}>((props) => (
  <article class="stat-card">
    <div class="stat-icon">
      <Icon name={props.icon} size={21} />
    </div>
    <span>{props.label}</span>
    <strong class="tabular">{props.value}</strong>
    <small>{props.detail}</small>
  </article>
));

const RootRow = component$<{
  root: MediaRoot;
  onOpen$: () => void;
}>((props) => (
  <button class="root-row" type="button" onClick$={props.onOpen$}>
    <span class="root-icon">
      <Icon name="folder" size={19} />
    </span>
    <span class="root-name">
      <strong>{props.root.label}</strong>
      <small>
        {props.root.scope} · {props.root.category}
      </small>
    </span>
    <span
      class={{ "availability-dot": true, available: props.root.available }}
    />
    <Icon name="arrow" size={17} />
  </button>
));

const LibraryView = component$<{
  state: DashboardState;
  loadItems$: (rootId: string) => void;
  scanRoot$: () => void;
  selectItem$: (item: CatalogItem) => void;
  previewRename$: () => void;
  confirmRename$: () => void;
}>((props) => {
  const selected = props.state.roots.find(
    (root) => root.id === props.state.selectedRootId,
  );
  return (
    <section class="library-layout">
      <aside class="panel root-picker">
        <div class="panel-heading">
          <div>
            <span class="section-label">Locations</span>
            <h3>Media roots</h3>
          </div>
        </div>
        <div class="root-list">
          {props.state.roots.map((root) => (
            <button
              class={{
                "root-choice": true,
                selected: root.id === props.state.selectedRootId,
              }}
              type="button"
              key={root.id}
              onClick$={() => props.loadItems$(root.id)}
            >
              <Icon name="folder" size={18} />
              <span>
                <strong>{root.label}</strong>
                <small>{root.scope}</small>
              </span>
              <span
                class={{ "availability-dot": true, available: root.available }}
              />
            </button>
          ))}
        </div>
      </aside>
      <section class="panel catalog-panel">
        <div class="panel-heading catalog-heading">
          <div>
            <span class="section-label">{selected?.category ?? "Library"}</span>
            <h3>{selected?.label ?? "Choose a root"}</h3>
          </div>
          {props.state.session?.canEdit && selected && (
            <button
              class="primary-button"
              type="button"
              disabled={props.state.scanning}
              onClick$={props.scanRoot$}
            >
              <Icon name="scan" size={18} />{" "}
              {props.state.scanning ? "Scanning…" : "Scan root"}
            </button>
          )}
        </div>
        {!selected ? (
          <EmptyState
            title="Choose a media root"
            detail="Select a registered location to inspect its catalog."
          />
        ) : props.state.items.length === 0 ? (
          <EmptyState
            title="No catalog entries yet"
            detail={
              props.state.session?.canEdit
                ? "Run a scan to reconcile this root with the catalog."
                : "An editor can scan this root to populate its catalog."
            }
          />
        ) : (
          <div
            class="item-table"
            role="table"
            aria-label={`${selected.label} items`}
          >
            <div class="item-row table-header" role="row">
              <span>Name</span>
              <span>Type</span>
              <span>Size</span>
            </div>
            {props.state.items.map((item) => (
              <button
                class={{
                  "item-row": true,
                  selected: props.state.selectedItemId === item.id,
                }}
                role="row"
                type="button"
                key={item.id}
                onClick$={() => props.selectItem$(item)}
              >
                <span class="item-name">
                  <Icon
                    name={item.mediaKind === "subtitle" ? "captions" : "tag"}
                    size={17}
                  />
                  <span>{item.relativePath}</span>
                </span>
                <span class="kind-pill">{item.mediaKind}</span>
                <span class="tabular muted">{formatBytes(item.sizeBytes)}</span>
              </button>
            ))}
          </div>
        )}
        {props.state.session?.canEdit && props.state.selectedItemId && (
          <div class="rename-workflow">
            <div class="rename-heading">
              <div>
                <span class="section-label">Guided organization</span>
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
              <span class="section-label">
                {conversion.mediaKind ?? "DVD video"}
              </span>
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
      <div class="intro-copy compact-intro">
        <span class="section-label">Sidecar workflow</span>
        <h2>Find the right words for an existing video.</h2>
        <p>
          Search OpenSubtitles or upload a UTF-8 subtitle. Every result becomes
          a no-overwrite preview before the broker places it beside the video.
          Online search checks the selected file hash first, then falls back to
          its title.
        </p>
      </div>

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
            <span class="section-label">1 · Choose video</span>
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
                    ? "No cataloged videos — scan this library first"
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
              <span class="section-label">2a · Online match</span>
              <h3>OpenSubtitles</h3>
            </div>
            <span class={{ "status-badge": true, live: providerAvailable }}>
              {providerAvailable ? "Configured" : "Not configured"}
            </span>
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
              <span class="section-label">2b · Local file</span>
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
              <span class="section-label">3 · Exact preview</span>
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

  return (
    <section class="metadata-layout">
      <div class="intro-copy compact-intro">
        <span class="section-label">Standards-based metadata</span>
        <h2>Describe media without rewriting the media itself.</h2>
        <p>
          Create Jellyfin-compatible NFO or book/audiobook OPF sidecars. Unknown
          values stay absent—especially release year—and existing metadata is
          never replaced silently.
        </p>
      </div>
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
      <section class="panel metadata-panel">
        <div class="panel-heading">
          <div>
            <span class="section-label">Catalog item</span>
            <h3>Metadata destination</h3>
          </div>
          <span class={{ "status-badge": true, live: props.session?.canEdit }}>
            {props.session?.canEdit ? "Editor" : "Viewer"}
          </span>
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
              disabled={metadata.loadingItems || metadata.items.length === 0}
              onChange$={(_, select) => chooseMetadataItem(select.value)}
            >
              <option value="">
                {metadata.loadingItems
                  ? "Loading media…"
                  : metadata.items.length === 0
                    ? "No cataloged items — scan this library first"
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
      {metadata.preview && (
        <section class="panel metadata-preview">
          <div class="panel-heading">
            <div>
              <span class="section-label">Exact plan</span>
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

const WorkflowPlaceholder = component$<{
  icon: IconName;
  title: string;
  description: string;
  mode?: string;
}>((props) => (
  <section class="workflow-stage">
    <div class="workflow-icon">
      <Icon name={props.icon} size={30} />
    </div>
    <span class="section-label">Staged workflow</span>
    <h2>{props.title}</h2>
    <p>{props.description}</p>
    <div class="safety-note">
      <Icon name="shield" size={18} />
      <span>
        <strong>
          {props.mode === "enabled"
            ? "Ready for staged plans"
            : "Read-only milestone"}
        </strong>
        <small>
          Nothing is written until a digest-bound preview is confirmed.
        </small>
      </span>
    </div>
  </section>
));

const RefreshView = component$<{ integrations: Integration[] }>((props) => {
  const refresh = useStore({ busyId: "", notice: "", error: "" });
  const triggerRefresh = $(async (integration: Integration) => {
    if (refresh.busyId) return;
    refresh.busyId = integration.id;
    refresh.notice = "";
    refresh.error = "";
    try {
      const result = await api<{ alreadyQueued: boolean }>(
        `/integrations/${encodeURIComponent(integration.id)}/refresh`,
        { method: "POST" },
      );
      refresh.notice = result.alreadyQueued
        ? `${integration.label} already has a refresh waiting to be dispatched.`
        : `${integration.label} refresh was queued.`;
    } catch (error) {
      refresh.error = readableError(error);
    } finally {
      refresh.busyId = "";
    }
  });
  return (
    <section class="single-column">
      <div class="intro-copy compact-intro">
        <span class="section-label">Optional adapters</span>
        <h2>Refresh an application when you need it.</h2>
        <p>
          Manual requests complement each application’s own watcher and timer.
          Missing applications stay visible but cannot affect Media Manager.
        </p>
      </div>
      {refresh.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{refresh.error}</span>
          <button type="button" onClick$={() => (refresh.error = "")}>
            ×
          </button>
        </div>
      )}
      {refresh.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{refresh.notice}</span>
        </div>
      )}
      <div class="integration-grid">
        {props.integrations.map((integration) => {
          const canRefresh = integration.capabilities.some((capability) =>
            ["library-refresh", "folder-rescan"].includes(capability),
          );
          return (
            <article class="integration-card" key={integration.id}>
              <div class="integration-icon">
                <Icon name="refresh" size={20} />
              </div>
              <div>
                <h3>{integration.label}</h3>
                <p>
                  {integration.capabilities.join(" · ") ||
                    "No manual adapter registered"}
                </p>
              </div>
              {canRefresh ? (
                <button
                  class="secondary-button compact-action"
                  type="button"
                  disabled={!integration.available || Boolean(refresh.busyId)}
                  onClick$={() => triggerRefresh(integration)}
                >
                  {refresh.busyId === integration.id ? "Queuing…" : "Refresh"}
                </button>
              ) : (
                <span
                  class={{ "status-badge": true, live: integration.available }}
                >
                  {integration.available ? "Observed" : "Not installed"}
                </span>
              )}
            </article>
          );
        })}
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
