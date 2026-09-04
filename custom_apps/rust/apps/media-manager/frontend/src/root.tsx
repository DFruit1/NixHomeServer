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
import { api, readableError } from "./api";
import { ConversionsView } from "./conversions-view";
import { Icon } from "./icon";
import {
  allowMetadataDraftDiscard,
  formatBytes,
  ItemEditor,
  profileForCategory,
  renameReady,
} from "./item-editor";
import { PlayerView } from "./player-view";
import { RefreshView } from "./refresh-view";
import { SubtitleView } from "./subtitle-view";
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
import { parseTvEpisodeFilename } from "./root-routing";
import {
  type ConversionEnvelope,
  type DashboardState,
  type IconName,
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

function beginItemEdit(
  state: DashboardState,
  roots: MediaRoot[],
  item: CatalogItem,
) {
  state.selectedItemId = item.id;
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
        ) : view.value === "health" ? (
          <MetadataHealthView
            roots={state.roots.filter(
              (root) => root.category !== "iso" && root.available,
            )}
            initialRootId={props.initialRootId}
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

  return (
    <section class="provider-accounts-page">
      <section class="provider-account-intro panel">
        <div>
          <h2>Provider accounts</h2>
          <p>
            Connect your own metadata and subtitle sources. Accounts belong to
            your signed-in identity, so another user's quota or lockout does not
            affect yours.
          </p>
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
                  {provider.logoUrl && (
                    <img
                      class="provider-logo"
                      src={provider.logoUrl}
                      alt={`${provider.name} logo`}
                      loading="lazy"
                    />
                  )}
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
                  {publicSource ? (
                    <span class="provider-state public-action">Public, no setup</span>
                  ) : provider.canConfigure &&
                    provider.credentialFields.length > 0 ? (
                    <button
                      class="primary-button"
                      type="button"
                      disabled={accounts.saving}
                      onClick$={() => openProvider(provider)}
                    >
                      {configured ? "Replace credentials" : "Set up"}
                    </button>
                  ) : null}
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
                    class="provider-doc-link"
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
  const previousCategory = useSignal(props.state.selectedCategory);
  useTask$(({ track }) => {
    const category = track(() => props.state.selectedCategory);
    if (category === previousCategory.value) return;
    previousCategory.value = category;
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
