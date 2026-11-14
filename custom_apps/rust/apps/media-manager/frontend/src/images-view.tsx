import {
  $,
  component$,
  useOnWindow,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import type {
  EyeAnalysis,
  ImmichAnalysisResponse,
  ImmichImage,
  ImmichIndexedPage,
  ImmichIndexStatus,
  ImmichImageResponse,
  ImmichTagMatch,
  ImmichTaggingState,
} from "./api-contract.generated";
import { Icon } from "./icon";
import { CollectionViewControl, useCollectionView } from "./collection-view";
import { DecisionQuestions } from "./decision-questions";
import {
  collectionTileSizes,
  thumbnailSrc,
  thumbnailSrcset,
} from "./thumbnail";
import { LoadingState } from "./view-states";

const photoPath = (id: string) =>
  `/provider-lookups/immich/images/${encodeURIComponent(id)}`;
const previewUrl = (id: string) => `/api/v1${photoPath(id)}/preview`;
const tagLabel = (tag: string) => tag.replaceAll("_", " ");

export const ImagesView = component$<{
  immichUrl?: string;
  userSubject?: string;
}>((props) => {
  const layout = useCollectionView(props, "images", "tiles-3");
  const detail = useSignal<HTMLElement>();
  const rulesOpen = useSignal(false);
  const rulesButton = useSignal<HTMLButtonElement>();
  const filtersOpen = useSignal(false);
  const moreOpen = useSignal(false);
  const pushedImageId = useSignal<string | null>(null);
  const state = useStore({
    items: [] as ImmichImage[],
    selected: undefined as ImmichImage | undefined,
    analysis: undefined as EyeAnalysis | undefined,
    filters: {
      tags: "",
      tagMode: "all",
      related: true,
      confidence: 50,
      minAesthetic: 0,
      minKeeper: 0,
      minCover: 0,
      sort: "capturedAt",
      direction: "desc",
      sortTag: "",
      aestheticWeight: 1,
      keeperWeight: 1,
      coverWeight: 1,
    },
    appliedFilters: "",
    index: undefined as ImmichIndexStatus | undefined,
    tagMatches: [] as ImmichTagMatch[],
    query: "",
    appliedQuery: "",
    nextPage: null as number | null,
    loading: true,
    loadingMore: false,
    selecting: false,
    analyzing: false,
    markingForRetag: false,
    selection: 0,
    listing: 0,
    error: "",
    detailError: "",
    setupRequired: false,
    automaticConnection: false,
    notice: "",
    imageFailed: false,
    failedPreviews: [] as string[],
  });

  const load = $(async (more = false) => {
    if (state.loadingMore || (more && (state.loading || !state.nextPage)))
      return;
    const listing = ++state.listing;
    if (more) state.loadingMore = true;
    else state.loading = true;
    state.error = "";
    state.setupRequired = false;
    try {
      const query = more ? state.appliedQuery : state.query.trim();
      const params = new URLSearchParams({
        page: String(more ? state.nextPage : 1),
        query,
      });
      const filters = more
        ? new URLSearchParams(state.appliedFilters)
        : new URLSearchParams(
            Object.entries(state.filters).map(([key, value]) => [
              key,
              ["confidence", "minAesthetic", "minKeeper", "minCover"].includes(
                key,
              )
                ? String(Number(value) / 100)
                : String(value),
            ]),
          );
      for (const key of ["tags", "sortTag"]) {
        const value = filters.get(key) ?? "";
        filters.set(
          key,
          value
            .split(",")
            .map((tag) =>
              key === "sortTag"
                ? tag.trim().toLowerCase().replaceAll(/\s+/g, "_")
                : tag.trim(),
            )
            .join(","),
        );
      }
      filters.forEach((value, key) => params.set(key, value));
      const result = await api<ImmichIndexedPage>(
        `/provider-lookups/immich/images/index?${params}`,
      );
      if (listing !== state.listing) return;
      state.appliedFilters = filters.toString();
      state.index = result.index;
      state.tagMatches = result.tagMatches;
      state.items = more
        ? [
            ...state.items,
            ...result.items.filter(
              (item) => !state.items.some((old) => old.id === item.id),
            ),
          ]
        : result.items;
      state.appliedQuery = query;
      state.nextPage = result.nextPage;
    } catch (error) {
      if (listing !== state.listing) return;
      state.error = readableError(error);
      state.setupRequired =
        error instanceof ApiError &&
        ["immich_account_required", "immich_provisioning_pending"].includes(
          error.code,
        );
      state.automaticConnection =
        error instanceof ApiError &&
        error.code === "immich_provisioning_pending";
    } finally {
      if (listing === state.listing) {
        state.loading = false;
        state.loadingMore = false;
      }
    }
  });
  useTask$(async () => {
    await load();
  });

  const choose = $(async (image: ImmichImage | string, pushHistory = true) => {
    if (state.analyzing && pushHistory) return;
    const imageId = typeof image === "string" ? image : image.id;
    const selection = ++state.selection;
    state.selected =
      typeof image === "string"
        ? state.items.find((candidate) => candidate.id === imageId)
        : image;
    state.analysis = state.selected?.analysis ?? undefined;
    state.detailError = "";
    state.notice = "";
    state.imageFailed = false;
    state.selecting = true;
    moreOpen.value = false;
    if (
      typeof window !== "undefined" &&
      pushHistory &&
      pushedImageId.value !== imageId
    ) {
      const historyState = { ...window.history.state, imageId };
      if (pushedImageId.value) {
        window.history.replaceState(historyState, "", window.location.href);
      } else {
        window.history.pushState(historyState, "", window.location.href);
      }
    }
    pushedImageId.value = imageId;
    if (typeof window !== "undefined" && window.innerWidth <= 920) {
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => resolve()),
      );
      detail.value?.scrollIntoView({ block: "start" });
    }
    try {
      const response = await api<ImmichImageResponse>(photoPath(imageId));
      if (selection === state.selection) {
        state.selected = response.image;
        state.analysis = response.analysis ?? undefined;
      }
    } catch (error) {
      if (selection === state.selection)
        state.detailError = readableError(error);
    } finally {
      if (selection === state.selection) state.selecting = false;
    }
  });

  const analyze = $(async () => {
    const image = state.selected;
    if (!image || state.analyzing || state.selecting) return;
    state.analyzing = true;
    state.detailError = "";
    state.notice = "";
    try {
      const response = await api<ImmichAnalysisResponse>(
        `${photoPath(image.id)}/analysis`,
        { method: "POST" },
      );
      if (response.assetId !== image.id || state.selected?.id !== image.id)
        return;
      state.analysis = response.analysis;
      state.selected.tagged = true;
      state.selected.analysis = response.analysis;
      const item = state.items.find((item) => item.id === image.id);
      if (item) {
        item.tagged = true;
        item.analysis = response.analysis;
      }
      state.notice = "Analysis saved in Media Manager.";
    } catch (error) {
      state.detailError = readableError(error);
    } finally {
      state.analyzing = false;
    }
  });

  const markForRetagging = $(async () => {
    const image = state.selected;
    if (!image || state.analyzing || state.selecting || state.markingForRetag)
      return;
    state.markingForRetag = true;
    state.detailError = "";
    state.notice = "";
    try {
      const result = await api<ImmichTaggingState>(
        `${photoPath(image.id)}/retag`,
        { method: "POST" },
      );
      if (result.assetId !== image.id)
        throw new Error("The retagging response did not match this photo.");
      const item = state.items.find((item) => item.id === image.id);
      if (item) item.tagged = result.tagged;
      if (state.selected?.id === image.id) {
        state.selected.tagged = result.tagged;
        state.notice =
          "Marked for retagging. Analyze now or wait for the next library sweep (up to 30 minutes).";
      }
    } catch (error) {
      if (state.selected?.id === image.id)
        state.detailError = readableError(error);
    } finally {
      state.markingForRetag = false;
    }
  });

  const closeSelectedImage = $(() => {
    ++state.selection;
    state.selecting = false;
    state.selected = undefined;
    state.analysis = undefined;
    state.imageFailed = false;
    state.detailError = "";
    state.notice = "";
    pushedImageId.value = null;
  });

  useVisibleTask$(
    () => {
      const imageId = (window.history.state as { imageId?: string } | null)
        ?.imageId;
      if (imageId && pushedImageId.value !== imageId)
        void choose(imageId, false);
    },
    { strategy: "document-ready" },
  );

  useOnWindow(
    "popstate",
    $((event: PopStateEvent) => {
      const imageId =
        (event.state as { imageId?: string } | null)?.imageId ?? null;
      if (imageId) {
        void choose(imageId, false);
        return;
      }
      void closeSelectedImage();
    }),
  );

  const searchTag = $((tag: string) => {
    state.filters.tags = tag;
    // A saved tag chip means that exact tag; related wording stays opt-in.
    state.filters.related = false;
    filtersOpen.value = true;
    return load();
  });

  const openRules = $(() => {
    moreOpen.value = false;
    rulesOpen.value = true;
  });
  const closeRules = $(async () => {
    rulesOpen.value = false;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => resolve()),
    );
    rulesButton.value?.focus();
  });

  useOnWindow(
    "keydown",
    $((event: KeyboardEvent) => {
      if (event.key === "Escape" && moreOpen.value) moreOpen.value = false;
    }),
  );
  useOnWindow(
    "click",
    $((event: MouseEvent) => {
      if (
        moreOpen.value &&
        !(event.target as Element | null)?.closest?.(".image-more")
      )
        moreOpen.value = false;
    }),
  );

  const busy = state.analyzing || state.markingForRetag;
  const sortReady =
    state.filters.sort !== "tag" || !!state.filters.sortTag.trim();
  const byDate = state.filters.sort === "capturedAt";
  const directionLabel =
    state.filters.direction === "desc"
      ? byDate
        ? "Newest first"
        : "Highest first"
      : byDate
        ? "Oldest first"
        : "Lowest first";
  const activeFilters =
    (state.filters.tags.trim() ? 1 : 0) +
    (["minAesthetic", "minKeeper", "minCover"] as const).filter(
      (key) => Number(state.filters[key]) > 0,
    ).length;
  const tiles = layout.view.value.startsWith("tiles-");
  const tileSizes = collectionTileSizes(layout.view.value, 72, {
    phone: "100vw",
    desktop: "420px",
  });
  return (
    <div class="images-page">
      <DecisionQuestions
        open={rulesOpen.value}
        image={state.selected}
        onClose$={closeRules}
        onAssessed$={(id, tags) => {
          if (state.selected?.id === id) state.selected.decisionTags = tags;
          const item = state.items.find((item) => item.id === id);
          if (item) item.decisionTags = tags;
        }}
      />
      <div class="images-workspace" hidden={rulesOpen.value}>
        <section
          ref={detail}
          class={{
            "image-detail": true,
            panel: true,
            "image-detail--selected": !!state.selected,
          }}
          role="region"
          tabIndex={0}
          aria-label="Selected photo"
          aria-busy={busy || state.selecting}
        >
          {state.selected ? (
            <>
              <div class="image-stage">
                {state.imageFailed ? (
                  <div class="image-preview-missing" role="status">
                    <Icon name="image" size={28} />
                    <p>
                      The preview is unavailable. Saved analysis is shown below.
                    </p>
                  </div>
                ) : (
                  <img
                    class="image-detail-preview"
                    key={state.selected.id}
                    src={previewUrl(state.selected.id)}
                    alt={state.selected.filename}
                    onError$={() => (state.imageFailed = true)}
                  />
                )}
              </div>
              <header class="image-detail-header">
                <h2>{state.selected.filename}</h2>
                {props.immichUrl && (
                  <a
                    href={`${props.immichUrl}/photos/${encodeURIComponent(state.selected.id)}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Open in Immich <span aria-hidden="true">↗</span>
                  </a>
                )}
              </header>
              <section class="image-eye" aria-labelledby="image-eye-heading">
                <div class="image-eye-head">
                  <h3 id="image-eye-heading">EYE</h3>
                  <span class="image-eye-status" role="status">
                    {state.analyzing
                      ? "Analyzing…"
                      : state.selected.tagged
                        ? "Tagged"
                        : "Awaiting tagging"}
                  </span>
                  <div class="image-eye-actions">
                    <button
                      type="button"
                      class="secondary-button"
                      disabled={busy || state.selecting}
                      onClick$={analyze}
                    >
                      {state.analysis ? "Analyze again" : "Analyze photo"}
                    </button>
                    <div class="image-more">
                      <button
                        type="button"
                        class="secondary-button"
                        aria-expanded={moreOpen.value}
                        aria-controls="image-more-actions"
                        disabled={busy || state.selecting}
                        onClick$={() => (moreOpen.value = !moreOpen.value)}
                      >
                        {state.markingForRetag ? "Marking…" : "More"}
                      </button>
                      {moreOpen.value && (
                        <ul id="image-more-actions" class="image-more-actions">
                          <li>
                            <button
                              type="button"
                              onClick$={() => {
                                moreOpen.value = false;
                                return state.selected && choose(state.selected);
                              }}
                            >
                              Refresh analysis
                            </button>
                          </li>
                          {state.selected.tagged && (
                            <li>
                              <button
                                type="button"
                                onClick$={() => {
                                  moreOpen.value = false;
                                  return markForRetagging();
                                }}
                              >
                                Mark for retagging
                              </button>
                            </li>
                          )}
                        </ul>
                      )}
                    </div>
                  </div>
                </div>
                {state.detailError && (
                  <div class="message error" role="alert">
                    <span>{state.detailError}</span>
                  </div>
                )}
                {state.notice && (
                  <div class="message success" role="status">
                    <span>{state.notice}</span>
                  </div>
                )}
                {state.analysis && (
                  <>
                    <dl class="image-scores">
                      {(["aesthetic", "keeper", "cover"] as const).map(
                        (score) => (
                          <div key={score}>
                            <dt>
                              {score === "aesthetic"
                                ? "Aesthetic"
                                : score === "keeper"
                                  ? "Keeper"
                                  : "Cover"}
                            </dt>
                            <dd>
                              {Math.round(state.analysis!.scores[score] * 100)}
                            </dd>
                          </div>
                        ),
                      )}
                    </dl>
                    {state.analysis.suggestions.length ? (
                      <ul class="image-chips" aria-label="Tags">
                        {state.analysis.suggestions.map((suggestion) => (
                          <li key={suggestion.tag}>
                            <button
                              type="button"
                              class="image-chip"
                              onClick$={() => searchTag(suggestion.tag)}
                              aria-label={`Find photos tagged ${tagLabel(suggestion.tag)}, ${Math.round(suggestion.confidence * 100)}% confidence`}
                            >
                              {tagLabel(suggestion.tag)}
                              <span class="image-chip-meta">
                                {Math.round(suggestion.confidence * 100)}%
                              </span>
                            </button>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <p class="image-analysis-note">
                        No suggested tags for this photo.
                      </p>
                    )}
                  </>
                )}
                {!!state.selected.decisionTags?.length && (
                  <div class="image-decision-tags">
                    <h4 id="image-decision-tags">Decision tags</h4>
                    <ul
                      class="image-chips"
                      aria-labelledby="image-decision-tags"
                    >
                      {state.selected.decisionTags.map((tag) => (
                        <li key={tag}>
                          <button
                            type="button"
                            class="image-chip"
                            aria-label={`Find photos tagged ${tag}`}
                            onClick$={() => searchTag(tag)}
                          >
                            {tag}
                          </button>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </section>
            </>
          ) : (
            <div class="image-focus image-focus--empty">
              <Icon name="image" size={28} />
              <h2>Choose a photo</h2>
              <p>Select a photo to see its saved tags and scores.</p>
            </div>
          )}
        </section>
        <section class="images-browser" aria-label="Immich photos">
          <header class="images-browser-header">
            <h2>Photos</h2>
            <div class="images-header-actions">
              <button
                ref={rulesButton}
                type="button"
                class="text-button images-rules-button"
                aria-controls="decision-editor"
                aria-expanded={rulesOpen.value}
                onClick$={openRules}
              >
                Decision questions
              </button>
              <CollectionViewControl
                label="View"
                hideCaption
                value={layout.view.value}
                onChange$={layout.change}
              />
            </div>
          </header>
          <div class="images-browser-body">
            <form
              class="images-search"
              preventdefault:submit
              onSubmit$={() => load()}
            >
              <div class="images-toolbar">
                <div class="images-search-field">
                  <label for="image-search" class="sr-only">
                    Search filenames
                  </label>
                  <input
                    id="image-search"
                    type="search"
                    maxLength={200}
                    value={state.query}
                    onInput$={(_, input) => (state.query = input.value)}
                    placeholder="Search"
                  />
                  <button
                    class="images-search-submit"
                    type="submit"
                    aria-label="Search"
                    disabled={state.loading || state.loadingMore}
                  >
                    <Icon name="search" size={18} />
                  </button>
                </div>
                <div class="images-sort">
                  <select
                    aria-label="Sort by"
                    value={state.filters.sort}
                    onChange$={(_, el) => {
                      state.filters.sort = el.value;
                      if (["tag", "scores"].includes(el.value))
                        filtersOpen.value = true;
                      if (el.value !== "tag" || state.filters.sortTag.trim())
                        return load();
                    }}
                  >
                    <option value="capturedAt">Date taken</option>
                    <option value="aesthetic">Aesthetic</option>
                    <option value="keeper">Keeper</option>
                    <option value="cover">Cover</option>
                    <option value="scores">Combined scores</option>
                    <option value="tag">Tag confidence</option>
                  </select>
                  <button
                    type="button"
                    class={{
                      "secondary-button": true,
                      "images-icon-button": true,
                      "images-direction": true,
                      ascending: state.filters.direction === "asc",
                    }}
                    aria-label={directionLabel}
                    title={directionLabel}
                    onClick$={() => {
                      state.filters.direction =
                        state.filters.direction === "desc" ? "asc" : "desc";
                      if (sortReady) return load();
                    }}
                  >
                    <Icon name="arrow" size={18} />
                  </button>
                  <button
                    type="button"
                    class="secondary-button images-icon-button images-filter-toggle"
                    aria-expanded={filtersOpen.value}
                    aria-controls="image-filters"
                    aria-label={
                      activeFilters
                        ? `Filters, ${activeFilters} active`
                        : "Filters"
                    }
                    title="Filters"
                    onClick$={() => (filtersOpen.value = !filtersOpen.value)}
                  >
                    <svg
                      aria-hidden="true"
                      width="18"
                      height="18"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.75"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M4 6h16M7 12h10M10 18h4" />
                    </svg>
                    {activeFilters > 0 && (
                      <span class="images-filter-count" aria-hidden="true">
                        {activeFilters}
                      </span>
                    )}
                  </button>
                </div>
              </div>
              <div
                id="image-filters"
                class="images-filters"
                hidden={!filtersOpen.value}
              >
                <div class="images-filter-row images-filter-tags">
                  <label>
                    Tags
                    <input
                      type="text"
                      maxLength={3104}
                      value={state.filters.tags}
                      placeholder="beach, people"
                      onInput$={(_, el) => (state.filters.tags = el.value)}
                    />
                  </label>
                  <label>
                    Match
                    <select
                      value={state.filters.tagMode}
                      onChange$={(_, el) => (state.filters.tagMode = el.value)}
                    >
                      <option value="all">All tags</option>
                      <option value="any">Any tag</option>
                    </select>
                  </label>
                </div>
                <label class="checkbox-field">
                  <input
                    type="checkbox"
                    checked={state.filters.related}
                    onChange$={(_, el) => (state.filters.related = el.checked)}
                  />
                  Also match related tags
                </label>
                {state.tagMatches.length > 0 && (
                  <p class="images-filter-note">
                    Also matched:{" "}
                    {state.tagMatches
                      .map(
                        (match) =>
                          `${tagLabel(match.term)} → ${match.tags
                            .map(tagLabel)
                            .join(", ")}`,
                      )
                      .join("; ")}
                  </p>
                )}
                {state.filters.sort === "tag" && (
                  <label>
                    Tag to sort by
                    <input
                      type="text"
                      required
                      pattern="[a-z0-9_]+"
                      maxLength={96}
                      value={state.filters.sortTag}
                      placeholder="beach"
                      onInput$={(_, el) => (state.filters.sortTag = el.value)}
                    />
                  </label>
                )}
                {state.filters.sort === "scores" && (
                  <fieldset class="images-filter-group">
                    <legend>Score weights</legend>
                    <div class="images-filter-row images-filter-row--3">
                      {(
                        [
                          "aestheticWeight",
                          "keeperWeight",
                          "coverWeight",
                        ] as const
                      ).map((key) => (
                        <label key={key}>
                          {key === "aestheticWeight"
                            ? "Aesthetic"
                            : key === "keeperWeight"
                              ? "Keeper"
                              : "Cover"}
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step="any"
                            value={state.filters[key]}
                            onInput$={(_, el) =>
                              (state.filters[key] = Number(el.value))
                            }
                          />
                        </label>
                      ))}
                    </div>
                    <p class="images-filter-note">
                      Use 0 to ignore a score; at least one must be above 0.
                    </p>
                  </fieldset>
                )}
                <fieldset class="images-filter-group">
                  <legend>Minimum scores and confidence (0–100)</legend>
                  <div class="images-filter-row images-filter-row--4">
                    {(
                      [
                        "minAesthetic",
                        "minKeeper",
                        "minCover",
                        "confidence",
                      ] as const
                    ).map((key) => (
                      <label key={key}>
                        {key === "confidence"
                          ? "Tag confidence"
                          : key.replace("min", "")}
                        <input
                          type="number"
                          min={0}
                          max={100}
                          value={state.filters[key]}
                          onInput$={(_, el) =>
                            (state.filters[key] = Number(el.value))
                          }
                        />
                      </label>
                    ))}
                  </div>
                </fieldset>
                <button type="submit" class="secondary-button">
                  Apply filters
                </button>
              </div>
            </form>
            {state.index?.error && (
              <div class="message error" role="alert">
                <span>Indexing needs attention: {state.index.error}</span>
              </div>
            )}
            {state.index && (
              <p class="images-index-line">
                <span role="status">
                  {state.index.analyzed.toLocaleString()} of{" "}
                  {state.index.discovered.toLocaleString()} analyzed
                  {state.index.error
                    ? " · retry scheduled"
                    : state.index.scanning
                      ? " · indexing…"
                      : ""}
                  {state.index.failed
                    ? ` · ${state.index.failed.toLocaleString()} awaiting retry`
                    : ""}
                </span>
                <button
                  type="button"
                  class="text-button"
                  disabled={state.loading || state.loadingMore}
                  onClick$={() => load()}
                >
                  Refresh
                </button>
              </p>
            )}
            {state.error && (
              <div class="message error" role="alert">
                <span>{state.error}</span>
              </div>
            )}
            {state.setupRequired ? (
              <div class="images-empty">
                <h2>Connect your Immich library</h2>
                <p>
                  {state.automaticConnection
                    ? "Sign into Photos once to create your account. Media Manager connects automatically within a few minutes, without an API key."
                    : "Add your Immich API key under Metadata sources → Immich, then return here."}
                </p>
                <div class="images-empty-actions">
                  <a
                    class="primary-button"
                    href={
                      state.automaticConnection
                        ? (props.immichUrl ?? "?view=accounts")
                        : "?view=accounts"
                    }
                  >
                    {state.automaticConnection
                      ? "Open Photos"
                      : "Open Metadata sources"}
                  </a>
                  <button
                    type="button"
                    class="text-button"
                    onClick$={() => load()}
                  >
                    Try again
                  </button>
                </div>
              </div>
            ) : state.loading ? (
              <LoadingState />
            ) : (
              <>
                {!state.items.length && (
                  <div class="images-empty">
                    <h2>No photos found</h2>
                    <p>
                      {state.appliedQuery
                        ? "Try different tags, scores or a filename."
                        : "Photos appear as background indexing discovers your library. Refresh to see progress."}
                    </p>
                  </div>
                )}
                <div
                  class="images-grid collection-layout"
                  data-view={layout.view.value}
                >
                  {state.items.map((image) => (
                    <button
                      key={image.id}
                      type="button"
                      class={{
                        "image-tile": true,
                        selected: state.selected?.id === image.id,
                      }}
                      aria-pressed={state.selected?.id === image.id}
                      title={tiles ? image.filename : undefined}
                      disabled={busy}
                      onClick$={() => choose(image)}
                    >
                      {layout.view.value !== "simple-list" &&
                        (state.failedPreviews.includes(image.id) ? (
                          <span
                            class="image-tile-placeholder"
                            role="img"
                            aria-label="Preview unavailable"
                          >
                            <Icon name="image" size={28} />
                            <span>Preview unavailable</span>
                          </span>
                        ) : (
                          <img
                            src={thumbnailSrc(previewUrl(image.id))}
                            srcset={thumbnailSrcset(previewUrl(image.id))}
                            sizes={tileSizes}
                            alt=""
                            loading="lazy"
                            width={240}
                            height={200}
                            onError$={() => {
                              state.failedPreviews = [
                                ...state.failedPreviews,
                                image.id,
                              ];
                            }}
                          />
                        ))}
                      <span class="image-item-copy">
                        <span class="image-item-name">{image.filename}</span>
                        {layout.view.value === "detailed-list" && (
                          <>
                            <span class="image-item-meta">
                              {image.capturedAt.slice(0, 10)}
                            </span>
                            <span class="image-item-meta">
                              {image.analysis
                                ? `Aesthetic ${Math.round(image.analysis.scores.aesthetic * 100)} · Keeper ${Math.round(image.analysis.scores.keeper * 100)} · Cover ${Math.round(image.analysis.scores.cover * 100)}`
                                : "Not analyzed"}
                            </span>
                            {!!image.decisionTags?.length && (
                              <span class="image-item-meta">
                                {image.decisionTags.join(", ")}
                              </span>
                            )}
                            {image.analysis && (
                              <span class="image-item-meta">
                                {image.analysis.suggestions
                                  .slice(0, 3)
                                  .map((suggestion) => tagLabel(suggestion.tag))
                                  .join(", ")}
                              </span>
                            )}
                          </>
                        )}
                      </span>
                    </button>
                  ))}
                </div>
                {state.nextPage && (
                  <button
                    type="button"
                    class="secondary-button images-load-more"
                    disabled={state.loadingMore}
                    onClick$={() => load(true)}
                  >
                    {state.loadingMore ? "Loading photos…" : "Load more photos"}
                  </button>
                )}
                {state.error && !state.setupRequired && (
                  <button
                    type="button"
                    class="secondary-button"
                    onClick$={() => load()}
                  >
                    Retry loading photos
                  </button>
                )}
              </>
            )}
          </div>
        </section>
      </div>
    </div>
  );
});
