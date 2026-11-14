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
import { api, errorDetail, readableError } from "./api";
import type { ProviderTestResult } from "./api-contract.generated";
import { ActivityView } from "./activity-view";
import { ConversionsView } from "./conversions-view";
import { Icon } from "./icon";
import { AppNavigation } from "./app-navigation";
import { coverColors } from "./cover-palette";
import "./library-selection.css";
import {
  allowMetadataDraftDiscard,
  formatBytes,
  ItemEditor,
  profileForCategory,
  renameReady,
  type EditorCommandAction,
} from "./item-editor";
import { isLibraryKind, supportsMediaAction } from "./media-capabilities";
import { PlayerView } from "./player-view";
import { VideosView } from "./videos-view";
import { ImagesView } from "./images-view";
import { RefreshView } from "./refresh-view";
import {
  PROVIDER_SETUP_GUIDES,
  ProviderSetupGuide,
  ProviderUsageGuide,
} from "./provider-setup-guide";
import { EmptyState, LoadingState } from "./view-states";
import { MetadataHealthView } from "./metadata-health-view";
import {
  activeMetadataMatchSelection,
  defaultMetadataMatchSelection,
  MATCHABLE_METADATA_FIELDS as EDITABLE_METADATA_FIELDS,
  mergeMetadataProviderIds,
  metadataMatchRows,
  MetadataMatchWorkspace,
  selectedMetadataMatchPatch,
  type MetadataMatchCandidate,
  type MetadataMatchField,
  type MetadataMatchSelection,
} from "./metadata-match-workspace";
import {
  OpenLibraryPanel,
  type OpenLibraryCandidate,
} from "./open-library-panel";
import { GoogleBooksPanel } from "./google-books-panel";
import { MusicBrainzPanel } from "./musicbrainz-panel";
import { TmdbPanel } from "./tmdb-panel";
import {
  googleBooksMetadataMatchCandidate,
  metadataSourceEditorValue,
  musicMetadataMatchCandidate as providerMusicMatch,
  openLibraryMetadataMatchCandidate as providerOpenLibraryMatch,
  tmdbMetadataMatchCandidate as providerTmdbMatch,
  type GoogleBooksCandidate,
  type MusicCandidate,
  type MusicLookupMode,
  type TmdbCandidate,
  type TmdbDetails,
} from "./metadata-provider-candidates";
import {
  initialRouteFromSearch,
  itemFromSearch,
  parseTvEpisodeFilename,
  pathFromSearch,
  rootFromSearch,
  viewFromSearch,
} from "./root-routing";
import {
  type ConversionEnvelope,
  type DashboardState,
  type Integration,
  type IntegrationRefresh,
  type MediaRoot,
  type MetadataConsumer,
  type MetadataHealthIssue,
  type MetadataModificationTarget,
  type MetadataObservation,
  type MetadataSidecarInspection,
  type MutationPreview,
  type NamingProfile,
  type PlaybackTarget,
  type ProviderAccountState,
  type ProviderCatalogResponse,
  type ProviderCredentialField,
  type ProviderDefinition,
  type RootProps,
  type Session,
  type Status,
  type VideoProbe,
  type CatalogItem,
  type TvEpisodeFields,
  type View,
  NAV_ITEMS,
  selectedCatalogItem,
} from "./root-types";

export type { RootProps, TvEpisodeFields, View, IntegrationRefresh };
export type { MetadataFieldChange, MetadataSourceChoice } from "./item-editor";
export { metadataFieldChanges, metadataSourceChoices } from "./item-editor";

export {
  parseTvEpisodeFilename,
  refreshPresentation,
  initialRouteFromSearch,
  itemFromSearch,
  rootFromSearch,
  viewFromSearch,
} from "./root-routing";

async function loadRootItems(rootId: string, search = "", cursor?: string) {
  const params = new URLSearchParams({ rootId });
  if (search.trim()) params.set("search", search.trim());
  if (cursor) {
    params.set("cursor", cursor);
    params.set("pageSize", "500");
  }
  return api<{ items: CatalogItem[]; nextCursor?: string | null }>(
    `/items?${params}`,
  );
}

function beginItemEdit(
  state: DashboardState,
  roots: MediaRoot[],
  item: CatalogItem,
) {
  state.selectedItemId = item.id;
  state.selectedItemSnapshot = item;
  const category = roots.find((root) => root.id === item.rootId)?.category;
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
}

export default component$((props: RootProps) => {
  const view = useSignal<View>(props.initialView ?? "library");
  const route = useStore<RootProps>({ ...props });
  const playerOpened = useSignal(props.initialView === "player");
  const sidebarSide = useSignal<"left" | "right">("left");
  const menuOpen = useSignal(false);
  const state = useStore<DashboardState>({
    roots: [],
    items: [],
    itemCursors: {},
    itemsSearch: "",
    itemsLoading: false,
    itemsGeneration: 0,
    selectedRootId: "",
    selectedCategory: "",
    loading: true,
    error: "",
    errorDetail: "",
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
    miniPlayerItemId: "",
  });

  // eslint-disable-next-line qwik/no-use-visible-task -- sidebar preference is client-only
  useVisibleTask$(() => {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem("mm-sidebar-side");
      if (saved === "right" || saved === "left") sidebarSide.value = saved;
    }
  });

  useTask$(({ track }) => {
    const currentView = track(() => view.value);
    const requestedTrack = track(() => state.miniPlayerItemId);
    if (currentView === "player" || requestedTrack) playerOpened.value = true;
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

  const loadCategoryItems = $(
    async (category: string, search = "", firstPageOnly = false) => {
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
      state.itemsSearch = search;
      state.itemCursors = {};
      state.error = "";
      const generation = (state.itemsGeneration ?? 0) + 1;
      state.itemsGeneration = generation;
      state.itemsLoading = true;
      let first = true;
      try {
        const requests = categoryRoots.map(async (root) => {
          const result = await loadRootItems(root.id, search);
          if (state.itemsGeneration !== generation) return;
          const selection = result.items.find(
            (item) => item.id === state.selectedItemId,
          );
          if (selection) state.selectedItemSnapshot = selection;
          if (first) state.items = result.items;
          else {
            const merged = new Map(state.items.map((item) => [item.id, item]));
            for (const item of result.items) merged.set(item.id, item);
            state.items = [...merged.values()];
          }
          if (first) state.loading = false;
          first = false;
          state.itemCursors = {
            ...state.itemCursors,
            [root.id]: result.nextCursor ?? null,
          };
        });
        const completion = Promise.allSettled(requests).then((results) => {
          if (state.itemsGeneration !== generation) return;
          if (first) state.items = [];
          const failure = results.find(
            (result) => result.status === "rejected",
          );
          if (failure?.status === "rejected") {
            state.error = readableError(failure.reason);
            state.errorDetail = errorDetail(failure.reason);
          }
          state.itemsLoading = false;
        });
        // Initial rendering waits only for the first usable pane. Other roots
        // continue publishing under the same generation guard.
        if (firstPageOnly && requests.length > 1) await Promise.any(requests);
        else await completion;
      } catch (error) {
        if (state.itemsGeneration !== generation) return;
        state.error = readableError(error);
        state.errorDetail = errorDetail(error);
      }
    },
  );

  const loadMoreCategoryItems = $(async () => {
    if (state.itemsLoading) return;
    const generation = state.itemsGeneration;
    const search = state.itemsSearch ?? "";
    state.itemsLoading = true;
    try {
      await Promise.all(
        Object.entries(state.itemCursors ?? {}).map(
          async ([rootId, cursor]) => {
            if (!cursor) return;
            const result = await loadRootItems(rootId, search, cursor);
            if (state.itemsGeneration !== generation) return;
            const ids = new Set(state.items.map((item) => item.id));
            state.items = [
              ...state.items,
              ...result.items.filter((item) => !ids.has(item.id)),
            ];
            state.itemCursors = {
              ...state.itemCursors,
              [rootId]: result.nextCursor ?? null,
            };
          },
        ),
      );
    } catch (error) {
      if (state.itemsGeneration === generation) {
        state.error = readableError(error);
        state.errorDetail = errorDetail(error);
      }
    } finally {
      if (state.itemsGeneration === generation) state.itemsLoading = false;
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
        await loadCategoryItems(selectedRoot.category, "", true);
        let requestedItem = state.items.find(
          (item) =>
            item.id === props.initialItemId && item.rootId === selectedRoot.id,
        );
        if (!requestedItem && props.initialItemId) {
          const exactItem = await api<CatalogItem>(
            `/items/${encodeURIComponent(props.initialItemId)}`,
          );
          if (exactItem.rootId !== selectedRoot.id) {
            throw new Error("The linked item is not in the selected library.");
          }
          state.items = [...state.items, exactItem];
          requestedItem = exactItem;
        }
        if (requestedItem) beginItemEdit(state, roots, requestedItem);
      }
    } catch (error) {
      state.error = readableError(error);
      state.errorDetail = errorDetail(error);
    } finally {
      state.loading = false;
    }
  });

  const selectItem = $((item: CatalogItem) => {
    const changingItem = item.id !== state.selectedItemId;
    if (changingItem && !allowMetadataDraftDiscard(state.metadataDraftDirty))
      return;
    if (changingItem) state.metadataDraftDirty = false;
    beginItemEdit(state, state.roots, item);
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
      state.errorDetail = errorDetail(error);
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
      state.errorDetail = errorDetail(error);
    } finally {
      state.confirming = false;
    }
  });

  // Keep the audio owner mounted while same-app links change the visible page.
  // Native listeners prevent navigation synchronously, without disabling normal
  // modified clicks, downloads, external links or opening another tab.
  useVisibleTask$(({ cleanup }) => {
    if (typeof document === "undefined" || typeof window === "undefined")
      return;
    let revision = 0;
    const navigate = async (url: URL, push: boolean) => {
      if (!allowMetadataDraftDiscard(state.metadataDraftDirty)) return;
      const current = ++revision;
      const next = initialRouteFromSearch(url.search);
      state.metadataDraftDirty = false;
      if (next.initialView === "library") {
        const root =
          state.roots.find((r) => r.id === next.initialRootId) ??
          state.roots.find((r) => r.category === state.selectedCategory) ??
          state.roots[0];
        if (root) await loadCategoryItems(root.category, "", true);
        if (current !== revision) return;
        state.selectedRootId = root?.id ?? "";
        state.selectedItemId = "";
        if (next.initialItemId) {
          try {
            const item =
              state.items.find((i) => i.id === next.initialItemId) ??
              (await api<CatalogItem>(
                `/items/${encodeURIComponent(next.initialItemId)}`,
              ));
            if (current !== revision) return;
            if (next.initialRootId && item.rootId !== next.initialRootId) {
              throw new Error(
                "The linked item is not in the selected library.",
              );
            }
            if (!state.items.some((i) => i.id === item.id))
              state.items.push(item);
            beginItemEdit(state, state.roots, item);
          } catch (error) {
            state.error = readableError(error);
          }
        }
      }
      if (current !== revision) return;
      Object.assign(
        route,
        { initialRootId: "", initialItemId: "", initialPath: "" },
        next,
      );
      view.value = next.initialView ?? "library";
      if (push) window.history.pushState({}, "", url);
      window.scrollTo(0, 0);
    };
    const onClick = (event: MouseEvent) => {
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey ||
        event.altKey
      )
        return;
      const anchor = (event.target as Element | null)?.closest?.("a");
      if (
        !anchor ||
        anchor.hasAttribute("download") ||
        (anchor.target && anchor.target !== "_self")
      )
        return;
      const url = new URL(anchor.href, window.location.href);
      if (
        url.origin !== window.location.origin ||
        url.pathname !== window.location.pathname ||
        !url.searchParams.has("view") ||
        viewFromSearch(url.search) !== url.searchParams.get("view")
      )
        return;
      event.preventDefault();
      void navigate(url, true).catch((error) => {
        state.error = readableError(error);
      });
    };
    const onPopState = () => {
      // The library owns its within-page folder/item history.
      if (
        view.value === "library" &&
        viewFromSearch(window.location.search) === "library"
      )
        return;
      void navigate(new URL(window.location.href), false).catch((error) => {
        state.error = readableError(error);
      });
    };
    const onPlay = (event: Event) => {
      const playing = event.target;
      if (!(playing instanceof HTMLMediaElement)) return;
      document
        .querySelectorAll<HTMLMediaElement>("audio,video")
        .forEach((media) => {
          if (media !== playing && !media.paused) media.pause();
        });
    };
    document.addEventListener("click", onClick, true);
    document.addEventListener("play", onPlay, true);
    window.addEventListener("popstate", onPopState);
    cleanup(() => {
      document.removeEventListener("click", onClick, true);
      document.removeEventListener("play", onPlay, true);
      window.removeEventListener("popstate", onPopState);
    });
  });

  const currentConversions = state.conversions?.progress.conversions ?? [];
  return (
    <div
      class={{
        "app-shell": true,
        "has-mini-player": Boolean(state.musicMiniPlayerVisible),
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
          </div>
        </div>

        <AppNavigation view={view.value} />

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
          "main-content--health": view.value === "health",
          "main-content--library": view.value === "library",
          "main-content--conversions": view.value === "conversions",
          "main-content--videos": view.value === "videos",
          "main-content--images": view.value === "images",
        }}
      >
        <h1 class="sr-only">
          {NAV_ITEMS.find((item) => item.id === view.value)?.label ??
            "Activity"}
        </h1>

        {state.error && (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span title={state.errorDetail || undefined}>{state.error}</span>
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

        {!state.loading && playerOpened.value && (
          <PlayerView
            state={state}
            userSubject={state.session?.subject}
            active={view.value === "player"}
            initialItemId={
              view.value === "player" ? route.initialItemId : undefined
            }
            initialPath={
              view.value === "player" ? route.initialPath : undefined
            }
          />
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
            loadMoreItems$={loadMoreCategoryItems}
            initialRootId={route.initialRootId}
            initialPath={route.initialPath}
          />
        ) : view.value === "health" ? (
          <MetadataHealthView
            roots={state.roots.filter(
              (root) => root.category !== "iso" && root.available,
            )}
            initialRootId={route.initialRootId}
            canEdit={state.session?.canEdit ?? false}
            onPlayAudio$={(itemId) => {
              state.miniPlayerItemId = itemId;
            }}
          />
        ) : view.value === "conversions" ? (
          <ConversionsView
            initial={state.conversions}
            transcriptionAvailable={
              state.status?.integrations.some(
                (i) => i.id === "transcribe" && i.available,
              ) ?? false
            }
          />
        ) : view.value === "activity" ? (
          <ActivityView canEdit={state.session?.canEdit ?? false} />
        ) : view.value === "player" ? null : view.value === "videos" ? (
          <VideosView
            roots={state.roots}
            initialItemId={route.initialItemId}
            initialPath={route.initialPath}
          />
        ) : view.value === "images" ? (
          <ImagesView
            userSubject={state.session?.subject}
            immichUrl={
              state.status?.integrations.find(
                (integration) =>
                  integration.id === "immich" && integration.available,
              )?.url ?? undefined
            }
          />
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
    filter: "all" | "connected" | "setup";
    expandedProviderId: string;
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
    filter: "all",
    expandedProviderId: "",
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
          const test = await api<ProviderTestResult>(
            `/provider-accounts/${encodeURIComponent(provider.id)}/test`,
            { method: "POST" },
          );
          if (test.status === "ready") {
            accounts.notice = `${provider.name} was saved and connected. ${test.message}`;
          } else {
            accounts.notice = "";
            accounts.error = `${provider.name} was saved, but its connection needs attention: ${test.message}`;
          }
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
    accounts.notice = "";
    try {
      const response = await api<ProviderTestResult>(
        `/provider-accounts/${encodeURIComponent(provider.id)}/test`,
        { method: "POST" },
      );
      const message = `${provider.name}: ${response.message}`;
      if (response.status === "ready") accounts.notice = message;
      else accounts.error = message;
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

  const query = accounts.query.trim().toLowerCase();
  const matchingProviders = query
    ? accounts.providers.filter((provider) =>
        [provider.name, ...provider.mediaDomains, ...provider.capabilities]
          .join(" ")
          .toLowerCase()
          .includes(query),
      )
    : accounts.providers;
  const plannedProviders = matchingProviders.filter(
    (provider) => provider.implementationStatus === "planned",
  );
  const providers = matchingProviders
    .filter((provider) => {
      if (provider.implementationStatus === "planned") return false;
      const status = providerAccountStatus(provider);
      switch (accounts.filter) {
        case "connected":
          return status === "connected" || status === "untested";
        case "setup":
          return status === "notSetUp" || status === "attention";
        default:
          return true;
      }
    })
    .sort(
      (left, right) =>
        Number(right.account.state !== "notRequired") -
        Number(left.account.state !== "notRequired"),
    );
  const showPlanned = accounts.filter === "all" && plannedProviders.length > 0;

  const renderEditor = (provider: ProviderDefinition) => (
    <section
      class="provider-credential-editor"
      aria-labelledby={`provider-editor-${provider.id}`}
    >
      <div class="provider-credential-heading">
        <h4 id={`provider-editor-${provider.id}`}>
          {provider.account.state === "configured"
            ? "Replace credentials"
            : "Set up credentials"}
        </h4>
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
      <p class="credential-guidance" role="note">
        <Icon name="shield" size={18} />
        <span>
          {accounts.recoveryAdvice} Existing values are never loaded here, and
          saving replaces the complete set.
        </span>
      </p>
      <details class="provider-access-details">
        <summary>Get access for {provider.name}</summary>
        <div class="provider-access-scroll">
          {PROVIDER_SETUP_GUIDES[provider.id] ? (
            <ProviderSetupGuide providerId={provider.id} />
          ) : (
            <p>
              Create the requested credentials in your provider account.{" "}
              <a href={provider.setupUrl} target="_blank" rel="noreferrer">
                Open provider setup
              </a>
            </p>
          )}
        </div>
      </details>
      <form preventdefault:submit onSubmit$={saveProvider} autocomplete="off">
        <div class="credential-field-grid">
          {provider.credentialFields.map((field) => (
            <label key={field.id}>
              <span>
                {field.label}
                {field.isRequired ? " *" : ""}
              </span>
              <input
                type={field.inputType}
                name={`provider-${provider.id}-${field.id}`}
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
              <small>
                {PROVIDER_SETUP_GUIDES[provider.id]?.credentialHelp[field.id] ??
                  field.help}
              </small>
            </label>
          ))}
        </div>
        {provider.canTest && (
          <label class="provider-test-choice">
            <input
              type="checkbox"
              checked={accounts.testAfterSave}
              disabled={accounts.saving}
              onChange$={(_, input) => (accounts.testAfterSave = input.checked)}
            />
            <span>Test the connection after saving</span>
          </label>
        )}
        <p class="provider-save-help">
          {provider.canTest && accounts.testAfterSave
            ? "Testing checks account access and may count against your provider quota. Try the source on an item to verify matching or downloads."
            : "Saving replaces these credentials without testing account access. Your media files are unchanged."}
        </p>
        <div class="provider-credential-footer">
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
              : provider.canTest && accounts.testAfterSave
                ? "Save and test"
                : "Encrypt and save"}
          </button>
        </div>
      </form>
    </section>
  );

  const renderRow = (provider: ProviderDefinition) => {
    const status = providerAccountStatus(provider);
    const planned = provider.implementationStatus === "planned";
    const configured = provider.account.state === "configured";
    const editing = accounts.selectedProviderId === provider.id;
    const expanded = editing || accounts.expandedProviderId === provider.id;
    const canSetUp =
      !planned &&
      provider.account.state !== "notRequired" &&
      provider.canConfigure &&
      provider.credentialFields.length > 0;
    const detailsId = `provider-details-${provider.id}`;
    const toggle = $(async () => {
      if (editing) await closeProvider();
      accounts.expandedProviderId = expanded ? "" : provider.id;
    });
    return (
      <li
        class={{
          "provider-row": true,
          "is-expanded": expanded,
          "is-editing": editing,
        }}
        key={provider.id}
      >
        <div class="provider-row-summary">
          <h3 class="provider-row-heading">
            <button
              class="provider-row-toggle"
              type="button"
              aria-expanded={expanded}
              aria-controls={detailsId}
              onClick$={toggle}
            >
              <Icon
                name={expanded ? "chevron-down" : "chevron-right"}
                size={16}
              />
              <span class="provider-row-name">{provider.name}</span>
              <span class="provider-row-types">
                {provider.mediaDomains.join(" · ")}
              </span>
            </button>
          </h3>
          {!planned &&
            (status === "noSetup" ? (
              <span class="provider-state quiet">No setup needed</span>
            ) : (
              <span class={["provider-state", status]}>
                {PROVIDER_STATUS_LABELS[status]}
              </span>
            ))}
          {!planned && configured ? (
            <button
              class="secondary-button provider-row-action"
              type="button"
              aria-expanded={expanded}
              aria-controls={detailsId}
              onClick$={toggle}
            >
              Manage
            </button>
          ) : canSetUp && !editing ? (
            <button
              class="secondary-button provider-row-action"
              type="button"
              disabled={accounts.saving}
              onClick$={() => {
                accounts.expandedProviderId = provider.id;
                return openProvider(provider);
              }}
            >
              Set up
            </button>
          ) : null}
        </div>
        {expanded && (
          <div class="provider-row-details" id={detailsId}>
            <p>{provider.notes}</p>
            {provider.account.lastTestMessage && (
              <p
                class={{
                  "provider-last-test": true,
                  attention: status === "attention",
                }}
                key={provider.account.lastTestMessage}
              >
                Last test: {provider.account.lastTestMessage}
              </p>
            )}
            {editing ? (
              renderEditor(provider)
            ) : (
              <>
                <div class="provider-account-actions">
                  {configured && provider.canTest && !planned && (
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
                  {configured && canSetUp && (
                    <button
                      class="secondary-button"
                      type="button"
                      disabled={accounts.saving}
                      onClick$={() => openProvider(provider)}
                    >
                      Replace credentials
                    </button>
                  )}
                  <a
                    class="provider-doc-link"
                    href={provider.documentationUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Documentation
                  </a>
                  {configured && provider.setupKind !== "managed" && (
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
                {!planned && <ProviderUsageGuide providerId={provider.id} />}
                {planned && PROVIDER_SETUP_GUIDES[provider.id] && (
                  <details class="provider-planned-guide">
                    <summary>Account and API key guide</summary>
                    <p>
                      This provider is coming soon. You cannot save credentials
                      or use it here yet. Wait until it is available before
                      purchasing access.
                    </p>
                    <ProviderSetupGuide providerId={provider.id} />
                  </details>
                )}
              </>
            )}
          </div>
        )}
      </li>
    );
  };

  return (
    <section class="provider-accounts-page">
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
        <label class="library-filter provider-account-search">
          <Icon name="search" size={16} />
          <input
            type="search"
            aria-label="Filter metadata sources"
            placeholder="Find a source"
            value={accounts.query}
            onInput$={(_, input) => (accounts.query = input.value)}
          />
        </label>
        <div
          class="provider-filter-tabs"
          role="group"
          aria-label="Show metadata sources"
        >
          {(
            [
              ["all", "All"],
              ["connected", "Connected"],
              ["setup", "Needs setup"],
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
      </div>

      {accounts.loading ? (
        <LoadingState />
      ) : providers.length === 0 && !showPlanned ? (
        <p class="provider-empty" role="status">
          {accounts.query.trim()
            ? `No sources match “${accounts.query.trim()}”.`
            : accounts.filter === "connected"
              ? "No sources are connected yet."
              : accounts.filter === "setup"
                ? "Every source is set up."
                : "No metadata sources available."}
        </p>
      ) : (
        <div class="provider-list-panel">
          {providers.length > 0 && (
            <ul class="provider-list">{providers.map(renderRow)}</ul>
          )}
          {showPlanned && (
            <details class="provider-planned-section">
              <summary>
                <Icon name="chevron-right" size={16} />
                Coming soon
                <span class="provider-planned-count">
                  {plannedProviders.length}
                </span>
              </summary>
              <ul class="provider-list">{plannedProviders.map(renderRow)}</ul>
            </details>
          )}
        </div>
      )}
    </section>
  );
});

type ProviderAccountStatus =
  | "connected"
  | "untested"
  | "attention"
  | "notSetUp"
  | "noSetup";

const PROVIDER_STATUS_LABELS: Record<ProviderAccountStatus, string> = {
  connected: "Connected",
  untested: "Not tested",
  attention: "Needs attention",
  notSetUp: "Not set up",
  noSetup: "No setup needed",
};

function providerAccountStatus(
  provider: ProviderDefinition,
): ProviderAccountStatus {
  if (provider.account.state === "notRequired") return "noSetup";
  if (provider.account.state !== "configured") return "notSetUp";
  if (provider.account.lastTestStatus === "ready") return "connected";
  return provider.account.lastTestStatus ? "attention" : "untested";
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

function folderDisplayName(folder: string): string {
  return folder.replace(/^_+/, "") || folder;
}

function artworkCandidateId(
  status: Status | undefined,
  items: CatalogItem[],
  selectedItemId: string,
  selectedFolder: string,
): string {
  if (selectedItemId) return selectedItemId;
  if (!selectedFolder) return "";
  const prefix = `${selectedFolder}/`;
  const inside = items.filter((item) => item.relativePath.startsWith(prefix));
  return (
    inside.find((item) => isLibraryKind(status, item.mediaKind))?.id ??
    inside.find((item) => item.mediaKind === "artwork")?.id ??
    inside[0]?.id ??
    ""
  );
}

const MediaImage = component$<{
  imageId: string;
  title: string;
  item?: CatalogItem;
  state: DashboardState;
  canEditCover?: boolean;
  onEditCover$?: QRL<() => void>;
  onPalette$?: QRL<(imageId: string, colors: string[]) => void>;
}>(
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  (props) => {
    const failed = useSignal(false);
    const sourceInfo = useStore<{
      loading: boolean;
      error: string;
      sources: Array<{ id: string; label: string; status: string }>;
    }>({ loading: false, error: "", sources: [] });
    useTask$(async ({ track }) => {
      const imageId = track(() => props.imageId);
      const imageFailed = track(() => failed.value);
      sourceInfo.sources = [];
      sourceInfo.error = "";
      sourceInfo.loading = false;
      if (!imageId || !imageFailed) return;
      sourceInfo.loading = true;
      try {
        const result = await api<{ sources: typeof sourceInfo.sources }>(
          `/items/${encodeURIComponent(imageId)}/image/sources`,
        );
        if (props.imageId === imageId && failed.value)
          sourceInfo.sources = result.sources ?? [];
      } catch (error) {
        if (props.imageId === imageId) sourceInfo.error = readableError(error);
      } finally {
        if (props.imageId === imageId) sourceInfo.loading = false;
      }
    });
    useTask$(({ track }) => {
      track(() => props.imageId);
      failed.value = false;
    });
    const coverEditable =
      Boolean(props.canEditCover) &&
      Boolean(props.imageId) &&
      !failed.value &&
      Boolean(props.onEditCover$);
    const editCoverKeyDown$ = $((event: KeyboardEvent) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      props.onEditCover$?.();
    });
    return (
      <>
        <figure
          class={{ "media-image": true, editable: coverEditable }}
          role={coverEditable ? "button" : undefined}
          tabIndex={coverEditable ? 0 : undefined}
          aria-label={coverEditable ? "Edit cover image" : undefined}
          onClick$={coverEditable ? props.onEditCover$ : undefined}
          onKeyDown$={coverEditable ? editCoverKeyDown$ : undefined}
        >
          {props.imageId && !failed.value ? (
            <>
              <img
                key={props.imageId}
                data-cover-id={props.imageId}
                src={`/api/v1/items/${encodeURIComponent(props.imageId)}/image`}
                alt={`Cover artwork for ${props.title}`}
                loading="lazy"
                onLoad$={async (_, image) => {
                  const id = image.getAttribute("data-cover-id") ?? "";
                  try {
                    const colors = await coverColors(image);
                    if (id === props.imageId)
                      await props.onPalette$?.(id, colors);
                  } catch {
                    if (id === props.imageId) await props.onPalette$?.(id, []);
                  }
                }}
                onError$={(_, image) => {
                  if (image.getAttribute("data-cover-id") !== props.imageId)
                    return;
                  failed.value = true;
                  props.onPalette$?.(props.imageId, []);
                }}
              />
              {coverEditable && (
                <span class="media-image-edit" aria-hidden="true">
                  <Icon name="image" size={16} />
                  Edit cover
                </span>
              )}
            </>
          ) : (
            <span class="cover-thumbnail-empty">
              <Icon name="image" size={24} />
              <span>{props.imageId ? "No cover" : "No selection"}</span>
            </span>
          )}
        </figure>
        {props.imageId && failed.value && (
          <details class="media-image-placeholder cover-recovery">
            <summary>Cover options</summary>
            {sourceInfo.loading && <p role="status">Checking image sources…</p>}
            <dl class="image-source-list">
              {sourceInfo.sources.map((source) => (
                <div key={source.id}>
                  <dt>{source.label}</dt>
                  <dd>
                    {(
                      {
                        available: "Image found",
                        missing: "Not found",
                        unavailable: "Could not read",
                        unknown: "Not reported",
                        unsupported: "Not supported",
                      } as Record<string, string>
                    )[source.status] ?? "Not reported"}
                  </dd>
                </div>
              ))}
            </dl>
            {sourceInfo.error && (
              <p role="alert">Image sources could not be checked.</p>
            )}
            {props.item &&
              supportsMediaAction(
                props.state.status,
                props.item.mediaKind,
                "edit-artwork",
              ) && (
                <CoverArtCard
                  item={props.item}
                  state={props.state}
                  compact
                  heading="Upload image"
                  note=""
                  close$={() => {}}
                  closeLabel="Close image upload"
                />
              )}
          </details>
        )}
      </>
    );
  },
);

const CoverArtCard = component$<{
  item: CatalogItem;
  state: DashboardState;
  heading: string;
  note: string;
  close$: QRL<() => void>;
  closeLabel: string;
  compact?: boolean;
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
    <section
      class={
        props.compact
          ? "image-placeholder-upload"
          : "panel editor-card non-media-card"
      }
    >
      {!props.compact && (
        <div class="editor-heading">
          <div class="non-media-heading">
            <Icon name="image" size={18} />
            <h3>{props.heading}</h3>
          </div>
          <button
            class="close-button"
            type="button"
            aria-label={props.closeLabel}
            onClick$={props.close$}
          >
            ×
          </button>
        </div>
      )}
      <div class="non-media-body">
        {!props.compact && (
          <>
            <p>{props.note}</p>
            <code>{props.item.relativePath}</code>
          </>
        )}
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
            : props.compact
              ? "Upload image from device"
              : "Replace cover art"}
        </button>
        {replacement.preview && (
          <div class="non-media-confirm">
            {replacement.preview.warnings.map((warning) => (
              <p key={warning}>{warning}</p>
            ))}
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

const ItemQuickActions = component$<{
  item: CatalogItem;
  state: DashboardState;
  editorCommand: { action: EditorCommandAction; revision: number };
}>((props) => {
  const playback = useStore<{
    itemId: string;
    target?: PlaybackTarget;
    unavailableLabel: string;
  }>({ itemId: "", unavailableLabel: "" });
  useTask$(async ({ track }) => {
    const itemId = track(() => props.item.id);
    playback.itemId = itemId;
    playback.target = undefined;
    playback.unavailableLabel = "";
    if (!itemId) return;
    try {
      const result = await api<{ targets: PlaybackTarget[] }>(
        `/items/${encodeURIComponent(itemId)}/playback-targets`,
      );
      if (playback.itemId !== itemId) return;
      playback.target = (result.targets ?? []).find(
        (target) => target.available && target.url,
      );
      if (!playback.target) {
        playback.unavailableLabel = result.targets?.[0]?.label ?? "";
      }
    } catch {
      if (playback.itemId === itemId) playback.target = undefined;
    }
  });
  const playInline = supportsMediaAction(
    props.state.status,
    props.item.mediaKind,
    "play-inline",
  );
  const playTarget = playback.target;
  const startInPagePlayer = $(() => {
    props.state.miniPlayerItemId = props.item.id;
  });
  const sendEditorCommand = $((action: EditorCommandAction) => {
    props.editorCommand.action = action;
    props.editorCommand.revision += 1;
  });
  return (
    <div
      class="item-quick-actions"
      role="group"
      aria-label="Selected media actions"
    >
      {playInline ? (
        <button
          class="quick-action-button play"
          type="button"
          onClick$={startInPagePlayer}
        >
          <Icon name="play" size={17} />
          Play
        </button>
      ) : playTarget?.url ? (
        <a
          class="quick-action-button play"
          href={playTarget.url}
          target="_blank"
          rel="noreferrer"
        >
          <Icon name="play" size={17} />
          Play in {playTarget.label}
        </a>
      ) : (
        <button
          class="quick-action-button play"
          type="button"
          disabled
          title={
            playback.unavailableLabel
              ? `${playback.unavailableLabel} is not connected`
              : "No connected playback app for this file"
          }
        >
          <Icon name="play" size={17} />
          Play
        </button>
      )}
      <button
        class="quick-action-button"
        type="button"
        onClick$={() => sendEditorCommand("metadata")}
      >
        <Icon name="tag" size={17} />
        Metadata
      </button>
    </div>
  );
});

const CATEGORY_TABS: Array<{ id: string; label: string }> = [
  { id: "videos", label: "Videos" },
  { id: "music", label: "Music" },
  { id: "audiobooks", label: "Audiobooks" },
  { id: "podcasts", label: "Podcasts" },
  { id: "books", label: "Books" },
];

const LibraryPane = component$<{
  title: string;
  emptyTitle: string;
  browser: {
    expanded: Record<string, boolean>;
    activeByParent: Record<string, string>;
    selectedFolder: string;
  };
  items: CatalogItem[];
  focusPath?: string;
  hasMore?: boolean;
  selectedItemId: string;
  selectItem$: QRL<(item: CatalogItem) => void>;
  selectFolder$: QRL<(path: string) => void>;
}>((props) => {
  const tree = buildTree(props.items);
  const focusedNode = props.focusPath
    ? findTreeNode(tree, props.focusPath)
    : undefined;
  const displayedTree = focusedNode ? [focusedNode] : tree;
  const lastWhitespaceTapAt = useSignal(0);
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
        {props.items.length > 0 && (
          <span class="pane-count">
            {props.items.length} {props.items.length === 1 ? "item" : "items"}
            {props.hasMore ? " loaded" : ""}
          </span>
        )}
      </div>
      <div class="catalog-scroll-region">
        {props.focusPath && (
          <button
            type="button"
            class="text-button library-crumb"
            onClick$={() =>
              props.selectFolder$(
                props.focusPath!.split("/").slice(0, -1).join("/"),
              )
            }
          >
            <Icon name="chevron-left" size={16} />
            Up one level
          </button>
        )}
        {props.items.length === 0 ? (
          <p class="library-empty-line">{props.emptyTitle}</p>
        ) : (
          <>
            <div
              class="item-tree"
              role="tree"
              aria-label={`${props.title} items`}
              title={
                props.focusPath
                  ? "Double-click or double-tap empty space to go up one level"
                  : undefined
              }
              onClick$={(event) => {
                const target = event.target as HTMLElement | null;
                if (
                  !target ||
                  target.closest("button, a, input, select, textarea")
                )
                  return;
                if (!props.focusPath) return;
                const parentPath = props.focusPath
                  .split("/")
                  .slice(0, -1)
                  .join("/");
                const now = Date.now();
                const isDoubleTap = now - lastWhitespaceTapAt.value < 450;
                lastWhitespaceTapAt.value = isDoubleTap ? 0 : now;
                if (!isDoubleTap) return;
                if (parentPath) {
                  props.selectFolder$(parentPath);
                } else if (props.browser.selectedFolder) {
                  props.selectFolder$("");
                }
              }}
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
  closeSelection$: QRL<() => void>;
}>((props) => {
  const editorCommand = useStore<{
    action: EditorCommandAction;
    revision: number;
  }>({ action: "", revision: 0 });
  const coverEditing = useSignal(false);
  const palette = useSignal({ imageId: "", colors: [] as string[] });
  const crumbRef = useSignal<HTMLElement>();
  const heroRef = useSignal<HTMLElement>();
  const heroStuck = useSignal(false);
  // The header is sticky; mark it once content scrolls beneath it so it reads
  // as lifted above the editor rather than overlapping it. It is stuck when
  // the gap to the breadcrumb above it grows beyond the pane's normal gap.
  useVisibleTask$(({ cleanup }) => {
    if (typeof document === "undefined" || typeof window === "undefined")
      return;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const hero = heroRef.value;
      const crumb = crumbRef.value;
      if (!hero || !crumb) {
        heroStuck.value = false;
        return;
      }
      const pane = hero.parentElement;
      const gap = pane ? parseFloat(getComputedStyle(pane).rowGap) || 0 : 0;
      heroStuck.value =
        hero.getBoundingClientRect().top -
          crumb.getBoundingClientRect().bottom >
        gap + 1;
    };
    const schedule = () => {
      if (!frame) frame = window.requestAnimationFrame(measure);
    };
    document.addEventListener("scroll", schedule, {
      capture: true,
      passive: true,
    });
    window.addEventListener("resize", schedule, { passive: true });
    measure();
    cleanup(() => {
      document.removeEventListener("scroll", schedule, { capture: true });
      window.removeEventListener("resize", schedule);
      if (frame) window.cancelAnimationFrame(frame);
    });
  });
  useTask$(({ track }) => {
    track(() => props.state.selectedItemId);
    track(() => props.activeFolder);
    coverEditing.value = false;
  });
  const selectedMediaItem =
    props.selectedItem &&
    isLibraryKind(props.state.status, props.selectedItem.mediaKind)
      ? props.selectedItem
      : undefined;
  const artworkItems =
    props.selectedItem &&
    !props.state.items.some((item) => item.id === props.selectedItem?.id)
      ? [...props.state.items, props.selectedItem]
      : props.state.items;
  const imageId = artworkCandidateId(
    props.state.status,
    artworkItems,
    props.state.selectedItemId,
    props.activeFolder,
  );
  const imageItem = artworkItems.find((item) => item.id === imageId);
  const canEditCover =
    Boolean(selectedMediaItem) &&
    (props.state.session?.canEdit ?? false) &&
    supportsMediaAction(
      props.state.status,
      selectedMediaItem?.mediaKind,
      "edit-artwork",
    );
  const selectionRootId =
    props.selectedItem?.rootId ?? props.activeFolderRootId;
  const selectionContext =
    props.state.roots.find((root) => root.id === selectionRootId)?.label ??
    "Library details";
  const selectionParent = (
    props.selectedItem?.relativePath ?? props.activeFolder
  )
    .split("/")
    .slice(0, -1)
    .join("/");
  return (
    <div
      class={{
        "library-detail-pane": true,
        "detail-personal": props.placement === "personal",
        "detail-shared": props.placement === "shared",
      }}
      aria-label={`Selected ${props.placement === "personal" ? "shared" : "personal"} library details`}
    >
      {(props.selectedItem || props.activeFolder) && (
        <button
          type="button"
          ref={crumbRef}
          class="text-button library-crumb"
          onClick$={props.closeSelection$}
        >
          <Icon name="chevron-left" size={16} />
          Back to libraries
        </button>
      )}
      <section
        ref={heroRef}
        class={{ "library-selection-hero": true, stuck: heroStuck.value }}
        style={{
          "--cover-first":
            palette.value.imageId === imageId
              ? (palette.value.colors[0] ?? "var(--card)")
              : "var(--card)",
          "--cover-second":
            palette.value.imageId === imageId
              ? (palette.value.colors[1] ??
                palette.value.colors[0] ??
                "var(--card)")
              : "var(--card)",
          "--cover-third":
            palette.value.imageId === imageId
              ? (palette.value.colors[2] ??
                palette.value.colors[1] ??
                palette.value.colors[0] ??
                "var(--card)")
              : "var(--card)",
        }}
        aria-label="Selected library item"
      >
        <div class="root-picker-image">
          <MediaImage
            imageId={imageId}
            item={imageItem}
            state={props.state}
            title={props.imageTitle}
            canEditCover={canEditCover}
            onEditCover$={() => (coverEditing.value = !coverEditing.value)}
            onPalette$={(id, colors) => {
              palette.value = { imageId: id, colors };
            }}
          />
        </div>
        <div class="library-selection-copy">
          <span class="library-selection-context">{selectionContext}</span>
          <h2
            class={{
              "library-selection-title--long": props.imageTitle.length > 48,
            }}
          >
            <Icon name={props.selectedItem ? "file" : "folder"} size={16} />
            <span>{props.imageTitle || "Choose a title or folder"}</span>
          </h2>
          {selectionParent && <p>{selectionParent}</p>}
          {selectedMediaItem && (
            <ItemQuickActions
              item={selectedMediaItem}
              state={props.state}
              editorCommand={editorCommand}
            />
          )}
        </div>
        <span class="cover-palette" aria-hidden="true" />
      </section>
      {selectedMediaItem && coverEditing.value && (
        <CoverArtCard
          item={selectedMediaItem}
          state={props.state}
          heading="Edit cover image"
          note="Replace the artwork file that sits beside this media. Remote artwork can also be staged from the Explore tab."
          close$={() => (coverEditing.value = false)}
          closeLabel="Close cover image editor"
        />
      )}
      {props.selectedItem &&
        isLibraryKind(props.state.status, props.selectedItem.mediaKind) && (
          <ItemEditor
            showIdentity={false}
            state={props.state}
            previewRename$={props.previewRename$}
            confirmRename$={props.confirmRename$}
            command={editorCommand}
          />
        )}
      {props.selectedItem?.mediaKind === "artwork" && (
        <CoverArtCard
          item={props.selectedItem}
          state={props.state}
          heading="Image File (Cover Art)"
          note="This image is used as nearby cover art. It does not have editable media metadata of its own."
          close$={() => (props.state.selectedItemId = "")}
          closeLabel="Close image details"
        />
      )}
      {!props.selectedItem &&
        props.activeFolder &&
        props.activeFolderRootId && (
          <ItemEditor
            showIdentity={false}
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
  );
});

function scrollLibraryDetailToTop() {
  if (typeof window === "undefined") return;
  if (typeof window.matchMedia !== "function") return;
  if (!window.matchMedia("(max-width: 920px)").matches) return;
  const behavior: ScrollBehavior = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches
    ? "auto"
    : "smooth";
  window.requestAnimationFrame(() =>
    window.scrollTo({ top: 0, left: 0, behavior }),
  );
}

const LibraryView = component$<{
  state: DashboardState;
  selectItem$: QRL<(item: CatalogItem) => void>;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
  loadCategoryItems$: QRL<(category: string, search?: string) => Promise<void>>;
  loadMoreItems$: QRL<() => Promise<void>>;
  initialRootId?: string;
  initialPath?: string;
}>((props) => {
  const initialRoot = props.state.roots.find(
    (root) => root.id === props.initialRootId,
  );
  const folderRootId = useSignal(props.initialRootId ?? "");
  const personal = useStore({
    expanded: {} as Record<string, boolean>,
    activeByParent: {} as Record<string, string>,
    selectedFolder:
      initialRoot?.scope === "personal" ? (props.initialPath ?? "") : "",
  });
  const shared = useStore({
    expanded: {} as Record<string, boolean>,
    activeByParent: {} as Record<string, string>,
    selectedFolder:
      initialRoot?.scope === "shared" ? (props.initialPath ?? "") : "",
  });
  const previousCategory = useSignal(props.state.selectedCategory);
  const categoryTabs = useSignal<HTMLElement>();
  useVisibleTask$(({ track }) => {
    const category = track(() => props.state.selectedCategory);
    if (
      typeof window === "undefined" ||
      typeof window.matchMedia !== "function"
    )
      return;
    const tabs = categoryTabs.value;
    const active = tabs?.querySelector<HTMLElement>(
      `[data-category="${category}"]`,
    );
    if (!tabs || !active) return;
    const behavior: ScrollBehavior = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches
      ? "auto"
      : "smooth";
    tabs.scrollTo?.({
      left: Math.max(
        0,
        active.offsetLeft - (tabs.clientWidth - active.offsetWidth) / 2,
      ),
      behavior,
    });
  });
  const filter = useSignal("");
  useTask$(({ track }) => {
    const category = track(() => props.state.selectedCategory);
    if (category === previousCategory.value) return;
    previousCategory.value = category;
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
    filter.value = "";
  });
  const filterRevision = useSignal(0);
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
  const filterNeedle = filter.value.trim().toLowerCase();
  const filtering = filterNeedle.length > 0;
  const matchesFilter = (item: CatalogItem) => {
    if (!filtering) return true;
    const path = item.relativePath.toLowerCase();
    const name = (item.relativePath.split("/").at(-1) ?? "").toLowerCase();
    const stem = name.replace(/\.[^.]+$/, "");
    return path.includes(filterNeedle) || stem.includes(filterNeedle);
  };
  const visiblePersonalItems = filtering
    ? personalItems.filter(matchesFilter)
    : personalItems;
  const visibleSharedItems = filtering
    ? sharedItems.filter(matchesFilter)
    : sharedItems;
  const matchCount = visiblePersonalItems.length + visibleSharedItems.length;
  const advancedSearch = props.state.status?.integrations?.find(
    (integration) =>
      integration.capabilities.includes("advanced-search") &&
      Boolean(integration.url),
  );
  const selectedItem = selectedCatalogItem(props.state);
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
  const activeFolderRootId =
    folderRootId.value ||
    activeFolderItems.find((item) =>
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
    folderRootId.value =
      personalItems.find((item) => item.relativePath.startsWith(`${path}/`))
        ?.rootId ??
      personalRoots[0]?.id ??
      "";
    personal.selectedFolder = path;
    shared.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
    scrollLibraryDetailToTop();
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
    folderRootId.value =
      sharedItems.find((item) => item.relativePath.startsWith(`${path}/`))
        ?.rootId ??
      sharedRoots[0]?.id ??
      "";
    shared.selectedFolder = path;
    personal.selectedFolder = "";
    props.state.selectedItemId = "";
    props.state.preview = undefined;
    scrollLibraryDetailToTop();
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
    scrollLibraryDetailToTop();
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
    scrollLibraryDetailToTop();
  });
  const closeFolderEditor$ = $(() => {
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    props.state.metadataDraftDirty = false;
    personal.selectedFolder = "";
    shared.selectedFolder = "";
    props.state.preview = undefined;
    props.state.notice = "";
  });
  const pushedSelection = useSignal<string | null>(null);
  useTask$(({ track }) => {
    track(() => props.state.selectedItemId);
    track(() => personal.selectedFolder);
    track(() => shared.selectedFolder);
    if (typeof window === "undefined") return;
    const itemId = props.state.selectedItemId;
    const folder = personal.selectedFolder || shared.selectedFolder;
    const selectionKey = itemId
      ? `item:${itemId}`
      : folder
        ? `path:${folder}`
        : "";
    if (pushedSelection.value === selectionKey) return;
    const firstRun = pushedSelection.value === null;
    pushedSelection.value = selectionKey;
    if (firstRun) return;
    const selectedItem = itemId
      ? props.state.items.find((item) => item.id === itemId)
      : undefined;
    const itemRootId = selectedItem?.rootId ?? activeFolderRootId;
    const params = new URLSearchParams();
    params.set("view", "library");
    const rootId = itemRootId || props.state.selectedRootId;
    if (rootId) params.set("root", rootId);
    if (itemId) params.set("item", itemId);
    else if (folder) params.set("path", folder);
    window.history.pushState(
      {},
      "",
      `${window.location.pathname}?${params.toString()}`,
    );
  });
  const historyRevision = useSignal(0);
  useOnWindow(
    "popstate",
    $(async () => {
      if (typeof window === "undefined") return;
      if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
      const revision = ++historyRevision.value;
      const search = window.location.search;
      if (viewFromSearch(search) !== "library") return;
      const itemId = itemFromSearch(search);
      const folderPath = pathFromSearch(search);
      const rootId = rootFromSearch(search);
      const root = props.state.roots.find(
        (candidate) => candidate.id === rootId,
      );
      if (root && root.category !== props.state.selectedCategory) {
        await props.loadCategoryItems$(root.category);
        if (historyRevision.value !== revision) return;
      }
      if (root) props.state.selectedRootId = root.id;
      if (itemId) {
        let item = props.state.items.find(
          (candidate) => candidate.id === itemId,
        );
        if (!item) {
          try {
            item = await api<CatalogItem>(
              `/items/${encodeURIComponent(itemId)}`,
            );
            if (historyRevision.value !== revision) return;
            if (root && item.rootId !== root.id) return;
            props.state.items = [...props.state.items, item];
          } catch (error) {
            if (historyRevision.value !== revision) return;
            props.state.error = readableError(error);
            props.state.errorDetail = errorDetail(error);
            return;
          }
        }
        if (root && item.rootId !== root.id) return;
        personal.selectedFolder = "";
        shared.selectedFolder = "";
        pushedSelection.value = `item:${itemId}`;
        props.selectItem$(item);
        scrollLibraryDetailToTop();
        return;
      }
      if (folderPath) {
        folderRootId.value = root?.id ?? "";
        const scope =
          root?.scope ??
          (personalItems.some((item) =>
            item.relativePath.startsWith(`${folderPath}/`),
          )
            ? "personal"
            : "shared");
        if (scope === "personal") {
          personal.selectedFolder = folderPath;
          shared.selectedFolder = "";
        } else {
          shared.selectedFolder = folderPath;
          personal.selectedFolder = "";
        }
        pushedSelection.value = `path:${folderPath}`;
        props.state.selectedItemId = "";
        props.state.preview = undefined;
        return;
      }
      personal.selectedFolder = "";
      shared.selectedFolder = "";
      pushedSelection.value = "";
      props.state.selectedItemId = "";
      props.state.preview = undefined;
    }),
  );
  const refreshing = useSignal(false);
  const refreshLibrary$ = $(async () => {
    if (refreshing.value) return;
    refreshing.value = true;
    props.state.error = "";
    props.state.notice = "";
    try {
      for (const root of categoryRoots) {
        if (!root.available) continue;
        await api<{ result: unknown }>("/catalog/refresh", {
          method: "POST",
          body: JSON.stringify({ rootId: root.id }),
        });
      }
      await props.loadCategoryItems$(activeCategory, filter.value);
      props.state.notice = "The library was refreshed from disk.";
    } catch (error) {
      props.state.error = readableError(error);
      props.state.errorDetail = errorDetail(error);
    } finally {
      refreshing.value = false;
    }
  });
  const categoryNoun = (
    CATEGORY_TABS.find((tab) => tab.id === activeCategory)?.label ?? "media"
  ).toLowerCase();
  const personalEmpty = visiblePersonalItems.length === 0;
  const sharedEmpty = visibleSharedItems.length === 0;
  const layoutMode = activeScope
    ? activeScope
    : personalEmpty && sharedEmpty
      ? "empty"
      : personalEmpty || sharedEmpty
        ? "single"
        : "dual";
  const emptyLine = (scope: "personal" | "shared") =>
    filtering ? `No ${scope} matches` : `No ${scope} ${categoryNoun}`;
  const personalPane = (
    <LibraryPane
      title="Personal"
      emptyTitle={
        filtering ? "No personal matches" : `No personal ${categoryNoun}`
      }
      items={visiblePersonalItems}
      browser={personal}
      hasMore={personalRoots.some((root) =>
        Boolean(props.state.itemCursors?.[root.id]),
      )}
      focusPath={activeScope === "personal" ? activeFocusPath : ""}
      selectedItemId={props.state.selectedItemId}
      selectItem$={selectPersonalItem$}
      selectFolder$={selectPersonalFolder$}
    />
  );
  const sharedPane = (
    <LibraryPane
      title="Shared"
      emptyTitle={filtering ? "No shared matches" : `No shared ${categoryNoun}`}
      items={visibleSharedItems}
      browser={shared}
      hasMore={sharedRoots.some((root) =>
        Boolean(props.state.itemCursors?.[root.id]),
      )}
      focusPath={activeScope === "shared" ? activeFocusPath : ""}
      selectedItemId={props.state.selectedItemId}
      selectItem$={selectSharedItem$}
      selectFolder$={selectSharedFolder$}
    />
  );
  return (
    <section class="library-view">
      <div
        ref={categoryTabs}
        class="library-tabs"
        role="tablist"
        aria-label="Library categories"
      >
        {CATEGORY_TABS.map((tab) => {
          const hasRoots = libraryRoots.some(
            (root) => root.category === tab.id,
          );
          return (
            <button
              key={tab.id}
              data-category={tab.id}
              type="button"
              role="tab"
              aria-label={tab.label}
              aria-selected={activeCategory === tab.id}
              title={
                hasRoots
                  ? undefined
                  : `No ${tab.label.toLowerCase()} library is configured`
              }
              class={{
                "library-tab": true,
                active: activeCategory === tab.id,
                disabled: !hasRoots,
              }}
              disabled={!hasRoots}
              onClick$={() => props.loadCategoryItems$(tab.id)}
            >
              <span class="library-tab-label">{tab.label}</span>
            </button>
          );
        })}
      </div>
      <div class="library-toolbar">
        <label class="library-filter">
          <Icon name="search" size={16} />
          <input
            type="search"
            value={filter.value}
            placeholder="Filter titles and filenames"
            aria-label="Filter titles and filenames in this library"
            onInput$={async (_, input) => {
              filter.value = input.value;
              const revision = ++filterRevision.value;
              await new Promise((resolve) => setTimeout(resolve, 150));
              if (revision !== filterRevision.value) return;
              await props.loadCategoryItems$(
                props.state.selectedCategory,
                filter.value,
              );
            }}
          />
          {filtering && (
            <button
              type="button"
              class="library-filter-clear"
              aria-label="Clear filter"
              onClick$={async () => {
                filterRevision.value += 1;
                filter.value = "";
                await props.loadCategoryItems$(props.state.selectedCategory);
              }}
            >
              ×
            </button>
          )}
        </label>
        <button
          class="secondary-button library-refresh"
          type="button"
          disabled={refreshing.value}
          onClick$={refreshLibrary$}
          title="Scan this library from disk now"
          aria-label="Refresh this library from disk now"
        >
          <Icon name="refresh" size={16} />
          {refreshing.value ? "Refreshing…" : "Refresh"}
        </button>
        <div class="library-toolbar-trailing">
          {Object.values(props.state.itemCursors ?? {}).some(Boolean) && (
            <button
              type="button"
              class="secondary-button"
              disabled={props.state.itemsLoading}
              onClick$={props.loadMoreItems$}
            >
              Load more
            </button>
          )}
          {props.state.itemsLoading && <span role="status">Loading…</span>}
          {filtering && (
            <span class="library-filter-summary" role="status">
              {matchCount === 0
                ? `No matches for “${filter.value.trim()}”`
                : `${matchCount} match${matchCount === 1 ? "" : "es"}`}
            </span>
          )}
          {advancedSearch?.url && (
            <a
              class="text-button library-advanced-search"
              href={`${advancedSearch.url}/?q=${encodeURIComponent(filter.value.trim())}`}
              target="_blank"
              rel="noreferrer"
              title="Search titles, authors, and tags across all libraries in the Search app"
            >
              <Icon name="search" size={16} />
              Advanced search
            </a>
          )}
        </div>
      </div>
      <section
        class={{
          "library-layout": true,
          [`library-layout--${layoutMode}`]: true,
        }}
      >
        {layoutMode === "empty" ? (
          <EmptyState
            title={filtering ? "No matches" : `No ${categoryNoun} yet`}
            detail={
              filtering
                ? "Clear the filter to see every item."
                : "Add files to your personal or shared media folder."
            }
          />
        ) : (
          <>
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
                closeSelection$={() => selectSharedFolder$("")}
              />
            ) : personalEmpty ? (
              <p class="library-empty-line">{emptyLine("personal")}</p>
            ) : (
              personalPane
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
                closeSelection$={() => selectPersonalFolder$("")}
              />
            ) : sharedEmpty ? (
              <p class="library-empty-line">{emptyLine("shared")}</p>
            ) : (
              sharedPane
            )}
          </>
        )}
      </section>
    </section>
  );
});

function treeContainsItem(node: TreeNode, itemId: string): boolean {
  return (
    Boolean(itemId) &&
    (node.item?.id === itemId ||
      node.children.some((child) => treeContainsItem(child, itemId)))
  );
}

const TreeBranch = component$<{
  node: TreeNode;
  depth: number;
  browser: {
    expanded: Record<string, boolean>;
    activeByParent: Record<string, string>;
    selectedFolder: string;
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
          "wrap-title":
            Boolean(props.selectedFolder) &&
            node.path.startsWith(`${props.selectedFolder}/`),
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
  const expanded = props.browser.expanded[node.path] ?? props.depth === 0;
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
          "wrap-title": treeContainsItem(node, props.selectedItemId),
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
