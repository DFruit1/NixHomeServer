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
} from "./api-contract.generated";
import { Icon } from "./icon";
import { CollectionViewControl, useCollectionView } from "./collection-view";
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
  const filters = useSignal<HTMLDetailsElement>();
  const pushedImageId = useSignal<string | null>(null);
  const state = useStore({
    items: [] as ImmichImage[],
    selected: undefined as ImmichImage | undefined,
    analysis: undefined as EyeAnalysis | undefined,
    filters: {
      tags: "",
      tagMode: "all",
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
    query: "",
    appliedQuery: "",
    nextPage: null as number | null,
    loading: true,
    loadingMore: false,
    selecting: false,
    analyzing: false,
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
            .map((tag) => tag.trim().toLowerCase().replaceAll(/\s+/g, "_"))
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
      state.notice = "Analysis saved in Media Manager.";
    } catch (error) {
      state.detailError = readableError(error);
    } finally {
      state.analyzing = false;
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

  const busy = state.analyzing;
  return (
    <div class="images-workspace">
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
            <div class="image-focus">
              {state.imageFailed ? (
                <div class="images-empty" role="status">
                  <Icon name="image" size={32} />
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
              <div class="image-detail-actions">
                <button
                  type="button"
                  class="primary-button"
                  disabled={busy || state.selecting}
                  onClick$={analyze}
                >
                  {state.analyzing
                    ? "Analyzing photo…"
                    : state.analysis
                      ? "Analyze again"
                      : "Analyze photo"}
                </button>
                <button
                  type="button"
                  class="secondary-button"
                  disabled={busy || state.selecting}
                  onClick$={() => state.selected && choose(state.selected)}
                >
                  Refresh analysis
                </button>
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
              <section class="image-analysis" aria-label="EYE analysis">
                <h3>Saved analysis</h3>
                <dl class="image-scores">
                  {(["aesthetic", "keeper", "cover"] as const).map((score) => (
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
                        <span>/100</span>
                      </dd>
                    </div>
                  ))}
                </dl>
                <p class="muted">
                  Relative scores from EYE; higher is better. Tags and scores
                  are saved only in Media Manager.
                </p>
                <ul class="image-suggestions">
                  {state.analysis.suggestions.map((suggestion) => (
                    <li key={suggestion.tag}>
                      <button
                        type="button"
                        class="image-tag-filter"
                        onClick$={() => {
                          state.filters.tags = suggestion.tag;
                          if (filters.value) filters.value.open = true;
                          return load();
                        }}
                        aria-label={`Find photos tagged ${tagLabel(suggestion.tag)}`}
                      >
                        {tagLabel(suggestion.tag)}
                      </button>
                      <small>{Math.round(suggestion.confidence * 100)}%</small>
                    </li>
                  ))}
                </ul>
                {!state.analysis.suggestions.length && (
                  <p>No suggested tags for this photo.</p>
                )}
              </section>
            )}
          </>
        ) : (
          <div class="images-empty image-focus image-focus--empty">
            <Icon name="image" size={36} />
            <h2>Choose a photo</h2>
            <p>
              Browse saved tags and quality scores. Analysis runs automatically
              without changing your Immich library or image files.
            </p>
          </div>
        )}
      </section>
      <section class="images-browser" aria-label="Immich photos">
        <header class="images-browser-header">
          <h2>Photos</h2>
          <span>{state.items.length} loaded</span>
        </header>
        <div class="images-browser-body">
          <form
            class="images-search"
            preventdefault:submit
            onSubmit$={() => load()}
          >
            <label for="image-search" class="sr-only">
              Search filenames
            </label>
            <div class="images-search-controls">
              <input
                id="image-search"
                type="search"
                maxLength={200}
                value={state.query}
                onInput$={(_, input) => (state.query = input.value)}
                placeholder="Search filenames"
              />
              <button
                class="secondary-button"
                type="submit"
                disabled={state.loading || state.loadingMore}
              >
                Search
              </button>
            </div>
            <details
              ref={filters}
              class="images-filter-details images-search-filters"
            >
              <summary>Filter and sort</summary>
              <div class="images-filter-row">
                <label>
                  Tags (comma separated)
                  <input
                    type="text"
                    maxLength={3104}
                    value={state.filters.tags}
                    placeholder="beach, people"
                    onInput$={(_, el) => (state.filters.tags = el.value)}
                  />
                </label>
                <label>
                  Match tags
                  <select
                    value={state.filters.tagMode}
                    onChange$={(_, el) => (state.filters.tagMode = el.value)}
                  >
                    <option value="all">All tags</option>
                    <option value="any">Any tag</option>
                  </select>
                </label>
                <label>
                  Sort by
                  <select
                    value={state.filters.sort}
                    onChange$={(_, el) => (state.filters.sort = el.value)}
                  >
                    <option value="capturedAt">Date taken</option>
                    <option value="aesthetic">Aesthetic</option>
                    <option value="keeper">Keeper</option>
                    <option value="cover">Cover</option>
                    <option value="scores">Combined scores</option>
                    <option value="tag">Tag confidence</option>
                  </select>
                </label>
                <label>
                  Order
                  <select
                    value={state.filters.direction}
                    onChange$={(_, el) => (state.filters.direction = el.value)}
                  >
                    <option value="desc">Highest / newest first</option>
                    <option value="asc">Lowest / oldest first</option>
                  </select>
                </label>
              </div>
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
                <fieldset class="images-filter-row">
                  <legend>Score weights</legend>
                  {(
                    ["aestheticWeight", "keeperWeight", "coverWeight"] as const
                  ).map((key) => (
                    <label key={key}>
                      {key.replace("Weight", "")}
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
                  <p class="muted">
                    Higher weights have more influence. Use 0 to ignore a score;
                    at least one must be above 0.
                  </p>
                </fieldset>
              )}
              <details class="images-filter-details">
                <summary>Minimum scores and confidence</summary>
                <div class="images-filter-row">
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
                        ? "Tag confidence (%)"
                        : `${key.replace("min", "")} (0–100)`}
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
              </details>
            </details>
          </form>
          <div class="images-view-options">
            <CollectionViewControl
              label="Images view"
              value={layout.view.value}
              onChange$={layout.change}
            />
          </div>
          {state.index && (
            <div class="images-index-status" role="status">
              <p>
                {state.index.analyzed} of {state.index.discovered} discovered
                photos analyzed
                {state.index.error
                  ? " · Retry scheduled"
                  : state.index.scanning
                    ? " · Indexing…"
                    : " · Watching for new photos"}
                {state.index.failed
                  ? ` · ${state.index.failed} awaiting retry`
                  : ""}
              </p>
              {state.index.error && <p>{state.index.error}</p>}
              <button
                type="button"
                class="secondary-button"
                disabled={state.loading || state.loadingMore}
                onClick$={() => load()}
              >
                Refresh results
              </button>
            </div>
          )}
          {state.error && (
            <div class="message error" role="alert">
              <span>{state.error}</span>
            </div>
          )}
          {state.setupRequired ? (
            <div class="images-empty">
              <Icon name="image" size={32} />
              <h2>Connect your Immich library</h2>
              <p>
                {state.automaticConnection
                  ? "Sign into Photos once to create your account. Media Manager connects automatically within a few minutes, without an API key."
                  : "Add your Immich API key under Metadata sources → Immich, then return here."}
              </p>
              <a
                class="secondary-button"
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
                class="secondary-button"
                onClick$={() => load()}
              >
                Try again
              </button>
            </div>
          ) : state.loading ? (
            <LoadingState />
          ) : (
            <>
              {!state.items.length && (
                <div class="images-empty">
                  <Icon name="image" size={32} />
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
                          src={previewUrl(image.id)}
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
  );
});
