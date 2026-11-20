import {
  $,
  component$,
  noSerialize,
  type NoSerialize,
  useComputed$,
  useOnWindow,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import { pushRoute, useBackLayer } from "./back-layers";
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
import { installPhotoSelection } from "./photo-selection";
import { preparePhotoFiles } from "./photo-sharing";
import { LoadingState } from "./view-states";

const photoPath = (id: string) =>
  `/provider-lookups/immich/images/${encodeURIComponent(id)}`;
const previewUrl = (id: string) => `/api/v1${photoPath(id)}/preview`;
const tagLabel = (tag: string) => tag.replaceAll("_", " ");
// Short names for the compact sort control; the native picker keeps full names.
const sortLabels: Record<string, string> = {
  capturedAt: "Date",
  aesthetic: "Aesthetic",
  keeper: "Keeper",
  cover: "Cover",
  scores: "Best overall",
  tag: "Best tag match",
};
// Names for the three relative analysis scores (each shown as a percentage).
const scoreNames = {
  aesthetic: "Aesthetic",
  keeper: "Keeper",
  cover: "Cover",
} as const;
const scoreLine = (scores: EyeAnalysis["scores"]) =>
  (["aesthetic", "keeper", "cover"] as const)
    .map((score) => `${scoreNames[score]} ${Math.round(scores[score] * 100)}%`)
    .join(" · ");
/** When the photo was taken; the file name only when no date is known. */
const takenLabel = (image: ImmichImage, withTime = true): string => {
  const date = image.capturedAt ? new Date(image.capturedAt) : undefined;
  if (!date || Number.isNaN(date.getTime())) return image.filename;
  return date.toLocaleString(
    undefined,
    withTime
      ? { dateStyle: "medium", timeStyle: "short" }
      : { dateStyle: "medium" },
  );
};

export const ImagesView = component$<{
  immichUrl?: string;
  userSubject?: string;
}>((props) => {
  const layout = useCollectionView(props, "images", "tiles-3");
  const grid = useSignal<HTMLElement>();
  const loadMoreSentinel = useSignal<HTMLElement>();
  const selection = useStore({
    active: false,
    ids: [] as string[],
    preparing: false,
    error: "",
  });
  const shareSupported = useSignal(false);
  const shareFiles = useSignal<NoSerialize<File[]>>();
  const shareController = useSignal<NoSerialize<AbortController>>();
  const detail = useSignal<HTMLElement>();
  const rulesOpen = useSignal(false);
  const rulesButton = useSignal<HTMLButtonElement>();
  const filtersOpen = useSignal(false);
  const semanticSearch = useSignal(true);
  const moreOpen = useSignal(false);
  const headerMenuOpen = useSignal(false);
  const returnToPhoto = useSignal<{ id: string; top: number }>();
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
    nextCursor: null as number | null,
    loading: true,
    loadingMore: false,
    emptyBatch: false,
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
    unavailable: false,
    imageFailed: false,
    failedPreviews: [] as string[],
  });

  const load = $(async (more = false) => {
    if (
      state.loadingMore ||
      (more &&
        (state.loading || (!state.nextPage && state.nextCursor === null)))
    )
      return;
    if (!more) {
      selection.ids = [];
      selection.active = false;
    }
    const listing = ++state.listing;
    if (more) state.loadingMore = true;
    else state.loading = true;
    state.error = "";
    state.setupRequired = false;
    state.unavailable = false;
    try {
      const query = more ? state.appliedQuery : state.query.trim();
      const params = new URLSearchParams({
        page: String(more ? (state.nextPage ?? 1) : 1),
        query,
      });
      if (more && state.nextCursor !== null)
        params.set("cursor", String(state.nextCursor));
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
      if (!more && semanticSearch.value && state.filters.tags.trim()) {
        filters.set("semanticQuery", state.filters.tags.trim());
        filters.set("tags", "");
        filters.set("sort", "capturedAt");
      }
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
      const fresh = result.items.filter(
        (item) => !state.items.some((old) => old.id === item.id),
      );
      state.items = more ? [...state.items, ...fresh] : result.items;
      // Auto-load must not race through empty continuation batches; leave the
      // next page on the explicit Load more control instead.
      state.emptyBatch = more && !fresh.length;
      state.appliedQuery = query;
      state.nextPage = result.nextPage;
      state.nextCursor = result.nextCursor ?? null;
    } catch (error) {
      if (listing !== state.listing) return;
      state.error = readableError(error);
      state.setupRequired =
        error instanceof ApiError &&
        ["immich_account_required", "immich_provisioning_pending"].includes(
          error.code,
        );
      // Disabled on the server: nothing a user can set up in Online services.
      state.unavailable =
        error instanceof ApiError && error.code === "immich_unavailable";
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

  useVisibleTask$(
    ({ track, cleanup }) => {
      const element = track(() => grid.value);
      shareSupported.value =
        typeof navigator.share === "function" &&
        typeof navigator.canShare === "function";
      if (!element) return;
      cleanup(
        installPhotoSelection(element, {
          get: () => selection.ids,
          set: (ids) => {
            selection.ids = ids.slice(0, 200);
            selection.error =
              ids.length > 200 ? "Select up to 200 photos at a time." : "";
            if (!selection.ids.length) selection.active = false;
          },
          start: () => {
            selection.active = true;
          },
          loadMore: () => {
            if (state.nextPage || state.nextCursor !== null) void load(true);
          },
        }),
      );
    },
    { strategy: "document-ready" },
  );

  // Keep the gallery continuous: when the end sentinel comes near the
  // viewport, pull the next page. Re-runs after each page so a short batch
  // that still leaves the sentinel visible continues filling the scroller.
  useVisibleTask$(
    ({ track, cleanup }) => {
      const sentinel = track(() => loadMoreSentinel.value);
      if (!sentinel) return;
      track(() => state.items.length);
      track(() => state.nextPage);
      track(() => state.nextCursor);
      track(() => state.loading);
      track(() => state.loadingMore);
      track(() => state.emptyBatch);
      const scroller = sentinel.closest<HTMLElement>(".images-browser-body");
      const check = () => {
        if (
          state.loading ||
          state.loadingMore ||
          state.emptyBatch ||
          !state.items.length
        )
          return;
        if (!state.nextPage && state.nextCursor === null) return;
        // Start one near-screenful early; a larger margin would preload
        // several short batches before the user reaches the gallery end.
        if (sentinel.getBoundingClientRect().top <= window.innerHeight + 80)
          void load(true);
      };
      const frame = requestAnimationFrame(check);
      window.addEventListener("scroll", check, { passive: true });
      scroller?.addEventListener("scroll", check, { passive: true });
      cleanup(() => {
        cancelAnimationFrame(frame);
        window.removeEventListener("scroll", check);
        scroller?.removeEventListener("scroll", check);
      });
    },
    { strategy: "document-ready" },
  );

  useVisibleTask$(({ track, cleanup }) => {
    track(() => selection.ids.join(","));
    shareController.value?.abort();
    shareController.value = undefined;
    shareFiles.value = undefined;
    selection.preparing = false;
    cleanup(() => shareController.value?.abort());
  });

  const togglePhoto = $((id: string) => {
    selection.error = "";
    if (selection.ids.includes(id)) {
      selection.ids = selection.ids.filter((value) => value !== id);
      // The last deselected photo ends selection mode instead of leaving an
      // empty action bar with 0 selected.
      if (!selection.ids.length) selection.active = false;
    } else if (selection.ids.length < 200)
      selection.ids = [...selection.ids, id];
    else selection.error = "Select up to 200 photos at a time.";
  });

  const prepareShare = $(async () => {
    if (!selection.ids.length || selection.preparing) return;
    const ids = [...selection.ids];
    const controller = new AbortController();
    shareController.value = noSerialize(controller);
    selection.preparing = true;
    selection.error = "";
    const timeout = window.setTimeout(() => controller.abort(), 120_000);
    try {
      const photos = ids.map(
        (id) => state.items.find((photo) => photo.id === id)!,
      );
      const files = await preparePhotoFiles(photos, controller.signal);
      if (controller.signal.aborted) return;
      if (!navigator.canShare({ files }))
        throw new Error(
          "This browser cannot share these files. Download the selected photos instead.",
        );
      shareFiles.value = noSerialize(files);
    } catch (error) {
      if (shareController.value === controller)
        selection.error = controller.signal.aborted
          ? "Sharing preparation timed out. Try fewer photos."
          : readableError(error);
    } finally {
      window.clearTimeout(timeout);
      if (shareController.value === controller) selection.preparing = false;
    }
  });

  // File preparation can outlast transient activation. A separate ready button
  // opens the native share sheet directly from the next user gesture (MDN share()).
  const sharePhotos = $(async () => {
    const files = shareFiles.value;
    if (!files?.length) return;
    selection.error = "";
    try {
      await navigator.share({ files });
    } catch (error) {
      if (!(error instanceof DOMException && error.name === "AbortError"))
        selection.error = readableError(error);
    }
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
      window.innerWidth <= 920
    ) {
      const tile = document.querySelector<HTMLElement>(
        `[data-photo-id="${CSS.escape(imageId)}"]`,
      );
      if (tile)
        returnToPhoto.value = {
          id: imageId,
          top: tile.getBoundingClientRect().top,
        };
      pushRoute({ ...window.history.state, imageId }, window.location.href, {
        replace: Boolean(pushedImageId.value),
      });
      pushedImageId.value = imageId;
    } else if (!pushHistory) {
      pushedImageId.value = imageId;
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

  // Run after Qwik commits the selected pane, including the first selection.
  useVisibleTask$(({ track, cleanup }) => {
    const imageId = track(() => state.selected?.id);
    track(() => state.selection);
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => {
        if (imageId) {
          if (detail.value) detail.value.scrollTop = 0;
          if (window.innerWidth <= 920)
            window.scrollTo({ top: 0, behavior: "instant" });
        } else if (returnToPhoto.value && window.innerWidth <= 920) {
          const { id, top } = returnToPhoto.value;
          const tile = document.querySelector<HTMLElement>(
            `[data-photo-id="${CSS.escape(id)}"]`,
          );
          if (tile)
            window.scrollBy({
              top: tile.getBoundingClientRect().top - top,
              behavior: "instant",
            });
          returnToPhoto.value = undefined;
        }
      });
    });
    cleanup(() => cancelAnimationFrame(frame));
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
      state.notice = "Results saved.";
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
          "Marked to be checked again. Re-check now, or it happens automatically within 30 minutes.";
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
      if (new URLSearchParams(window.location.search).get("view") !== "images")
        return;
      const imageId =
        (event.state as { imageId?: string } | null)?.imageId ?? null;
      // Same photo: the entry belonged to an open layer (back-layers.ts).
      if (imageId === pushedImageId.value) return;
      selection.active = false;
      selection.ids = [];
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
    semanticSearch.value = false;
    filtersOpen.value = true;
    return load();
  });

  const openRules = $(() => {
    moreOpen.value = false;
    headerMenuOpen.value = false;
    rulesOpen.value = true;
  });
  const closeRules = $(async () => {
    rulesOpen.value = false;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => resolve()),
    );
    rulesButton.value?.focus();
  });

  // Back closes the decision editor, then leaves photo selection mode.
  useBackLayer("decision-questions", rulesOpen, closeRules);
  const selecting = useComputed$(() => selection.active);
  useBackLayer(
    "photo-selection",
    selecting,
    $(() => {
      selection.active = false;
      selection.ids = [];
    }),
  );

  useOnWindow(
    "keydown",
    $((event: KeyboardEvent) => {
      if (event.key === "Escape") {
        moreOpen.value = false;
        headerMenuOpen.value = false;
        selection.active = false;
        selection.ids = [];
      }
    }),
  );
  useOnWindow(
    "click",
    $((event: MouseEvent) => {
      const target = event.target as Element | null;
      if (moreOpen.value && !target?.closest?.(".image-more"))
        moreOpen.value = false;
      if (headerMenuOpen.value && !target?.closest?.(".images-header-menu"))
        headerMenuOpen.value = false;
    }),
  );

  const busy = state.analyzing || state.markingForRetag;
  const semanticActive = semanticSearch.value && !!state.filters.tags.trim();
  const sortReady =
    semanticActive ||
    state.filters.sort !== "tag" ||
    !!state.filters.sortTag.trim();
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
                    alt="Selected photo"
                    onError$={() => (state.imageFailed = true)}
                  />
                )}
              </div>
              <header class="image-detail-header">
                <h2 title={state.selected.filename}>
                  {takenLabel(state.selected)}
                </h2>
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
              <section class="image-eye" aria-label="Photo analysis">
                <div class="image-eye-head">
                  <p class="image-eye-status" role="status">
                    {state.analyzing
                      ? "Analysing…"
                      : state.selected.tagged
                        ? "Analysed"
                        : "Not analysed yet"}
                  </p>
                  <div class="image-eye-actions">
                    <button
                      type="button"
                      class="secondary-button"
                      disabled={busy || state.selecting}
                      onClick$={analyze}
                    >
                      {state.analysis
                        ? "Re-check this photo"
                        : "Check this photo"}
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
                        {state.markingForRetag ? "Marking…" : "More actions"}
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
                              Reload saved results
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
                                Check again later
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
                            <dt>{scoreNames[score]}</dt>
                            <dd>
                              {Math.round(state.analysis!.scores[score] * 100)}
                              <span class="image-score-scale">%</span>
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
          <header
            class={{
              "images-browser-header": true,
              "images-browser-header--selecting": selection.active,
            }}
          >
            <h2 class={{ "sr-only": selection.active }}>Photos</h2>
            {selection.active ? (
              <div
                class="images-selection-actions"
                role="region"
                aria-label="Selected photos"
              >
                <span role="status">{selection.ids.length} selected</span>
                {selection.ids.length ? (
                  <a
                    class="secondary-button"
                    download={
                      selection.ids.length === 1
                        ? state.items.find(
                            (photo) => photo.id === selection.ids[0],
                          )?.filename
                        : "photos.zip"
                    }
                    href={
                      selection.ids.length === 1
                        ? `/api/v1${photoPath(selection.ids[0])}/original`
                        : `/api/v1/provider-lookups/immich/images/download?${new URLSearchParams({ assetIds: selection.ids.join(",") })}`
                    }
                  >
                    Download
                  </a>
                ) : (
                  <button class="secondary-button" disabled>
                    Download
                  </button>
                )}
                {shareSupported.value && (
                  <button
                    type="button"
                    class="secondary-button"
                    disabled={!selection.ids.length || selection.preparing}
                    onClick$={shareFiles.value ? sharePhotos : prepareShare}
                  >
                    {selection.preparing
                      ? "Preparing…"
                      : shareFiles.value
                        ? "Share now"
                        : "Share"}
                  </button>
                )}
                <button
                  type="button"
                  class="images-header-icon"
                  aria-label="Cancel selection"
                  title="Cancel selection"
                  onClick$={() => {
                    selection.active = false;
                    selection.ids = [];
                    selection.error = "";
                  }}
                >
                  <Icon name="close" size={20} />
                </button>
                {selection.error && (
                  <p class="message error" role="alert">
                    {selection.error}
                  </p>
                )}
              </div>
            ) : (
              <div class="images-header-actions">
                <button
                  type="button"
                  class="images-header-icon"
                  aria-label="Select photos"
                  title="Select photos"
                  onClick$={() => {
                    selection.active = true;
                    selection.ids = [];
                    selection.error = "";
                    headerMenuOpen.value = false;
                  }}
                >
                  <Icon name="select" size={20} />
                </button>
                <CollectionViewControl
                  label="Layout"
                  compact
                  value={layout.view.value}
                  onChange$={layout.change}
                />
                <div class="images-header-menu">
                  <button
                    ref={rulesButton}
                    type="button"
                    class="images-header-icon"
                    aria-label="More photo options"
                    title="More"
                    aria-expanded={headerMenuOpen.value}
                    aria-controls="images-header-menu"
                    onClick$={() =>
                      (headerMenuOpen.value = !headerMenuOpen.value)
                    }
                  >
                    <Icon name="more" size={20} />
                  </button>
                  {headerMenuOpen.value && (
                    <ul
                      id="images-header-menu"
                      class="image-more-actions images-header-menu-list"
                    >
                      <li>
                        <button
                          type="button"
                          aria-controls="decision-editor"
                          onClick$={openRules}
                        >
                          Decision questions
                        </button>
                      </li>
                      <li>
                        <button
                          type="button"
                          disabled={state.loading || state.loadingMore}
                          onClick$={() => {
                            headerMenuOpen.value = false;
                            return load();
                          }}
                        >
                          Refresh photos
                        </button>
                      </li>
                      {state.index && (
                        <li class="images-header-menu-note">
                          {state.index.analyzed.toLocaleString()} of{" "}
                          {state.index.discovered.toLocaleString()} photos
                          analysed
                        </li>
                      )}
                    </ul>
                  )}
                </div>
              </div>
            )}
          </header>
          <div class="images-browser-body">
            <form
              class={{
                "images-search": true,
                "images-search--sticky":
                  !filtersOpen.value && !selection.active,
              }}
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
                  <label
                    class={{
                      "images-sort-chip": true,
                      "images-sort-chip--joined": !semanticActive,
                    }}
                  >
                    <span aria-hidden="true">
                      {semanticActive
                        ? "Relevance"
                        : (sortLabels[state.filters.sort] ?? "Sort")}
                    </span>
                    <Icon name="chevron-down" size={16} />
                    <select
                      aria-label="Sort by"
                      value={semanticActive ? "relevance" : state.filters.sort}
                      disabled={semanticActive}
                      onChange$={(_, el) => {
                        state.filters.sort = el.value;
                        if (["tag", "scores"].includes(el.value))
                          filtersOpen.value = true;
                        if (el.value !== "tag" || state.filters.sortTag.trim())
                          return load();
                      }}
                    >
                      {semanticActive && (
                        <option value="relevance">Relevance</option>
                      )}
                      <option value="capturedAt">Date taken</option>
                      <option value="aesthetic">Aesthetic</option>
                      <option value="keeper">Keeper</option>
                      <option value="cover">Cover</option>
                      <option value="scores">Best overall</option>
                      <option value="tag">Best tag match</option>
                    </select>
                  </label>
                  {!semanticActive && (
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
                  )}
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
                    {semanticSearch.value ? "Tags or description" : "Tags"}
                    <input
                      type="text"
                      maxLength={semanticSearch.value ? 200 : 3104}
                      value={state.filters.tags}
                      placeholder={
                        semanticSearch.value
                          ? "rocks beside the sea"
                          : "beach, people"
                      }
                      onInput$={(_, el) => (state.filters.tags = el.value)}
                    />
                  </label>
                  <label>
                    Search in
                    <select
                      value={semanticSearch.value ? "content" : "tags"}
                      onChange$={(_, el) =>
                        (semanticSearch.value = el.value === "content")
                      }
                    >
                      <option value="content">Image content</option>
                      <option value="tags">Saved tags</option>
                    </select>
                  </label>
                </div>
                {!semanticSearch.value && (
                  <>
                    <label>
                      Match
                      <select
                        value={state.filters.tagMode}
                        onChange$={(_, el) =>
                          (state.filters.tagMode = el.value)
                        }
                      >
                        <option value="all">All tags</option>
                        <option value="any">Any tag</option>
                      </select>
                    </label>
                    <label class="checkbox-field">
                      <input
                        type="checkbox"
                        checked={state.filters.related}
                        onChange$={(_, el) =>
                          (state.filters.related = el.checked)
                        }
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
                  </>
                )}
                {!semanticActive && state.filters.sort === "tag" && (
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
                {!semanticActive && state.filters.sort === "scores" && (
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
                            ? scoreNames.aesthetic
                            : key === "keeperWeight"
                              ? scoreNames.keeper
                              : scoreNames.cover}
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
                  <legend>
                    Minimum scores
                    {!semanticSearch.value ? " and tag match" : ""} (%)
                  </legend>
                  <div
                    class={`images-filter-row images-filter-row--${semanticSearch.value ? 3 : 4}`}
                  >
                    {(
                      [
                        "minAesthetic",
                        "minKeeper",
                        "minCover",
                        ...(!semanticSearch.value
                          ? ["confidence" as const]
                          : []),
                      ] as const
                    ).map((key) => (
                      <label key={key}>
                        {key === "confidence"
                          ? "Tag match"
                          : key === "minAesthetic"
                            ? scoreNames.aesthetic
                            : key === "minKeeper"
                              ? scoreNames.keeper
                              : scoreNames.cover}
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
                <span>Photo analysis needs attention: {state.index.error}</span>
              </div>
            )}
            {state.index &&
              (state.index.scanning ||
                state.index.failed > 0 ||
                !!state.index.error ||
                state.index.analyzed < state.index.discovered) && (
                <p class="images-index-line">
                  <span role="status">
                    {state.index.scanning
                      ? `Analysing ${state.index.analyzed.toLocaleString()} of ${state.index.discovered.toLocaleString()} photos`
                      : `${state.index.analyzed.toLocaleString()} of ${state.index.discovered.toLocaleString()} photos analysed`}
                    {state.index.error ? " · will try again shortly" : ""}
                    {state.index.failed
                      ? ` · ${state.index.failed.toLocaleString()} failed`
                      : ""}
                  </span>
                  <button
                    type="button"
                    class="images-header-icon images-index-refresh"
                    aria-label="Refresh photos"
                    title="Refresh photos"
                    disabled={state.loading || state.loadingMore}
                    onClick$={() => load()}
                  >
                    <Icon name="refresh" size={16} />
                  </button>
                </p>
              )}
            {state.error && !state.setupRequired && !state.unavailable && (
              <div class="message error" role="alert">
                <span>{state.error}</span>
              </div>
            )}
            {state.unavailable ? (
              <div class="images-empty">
                <h2>Photos isn't available on this server</h2>
              </div>
            ) : state.setupRequired ? (
              <div class="images-empty">
                <h2>Photos isn't connected yet</h2>
                <p>
                  {state.automaticConnection
                    ? "Sign into Photos once to create your account. Media Manager connects automatically within a few minutes, without an API key."
                    : "Add your Photos (Immich) API key under Online services, then come back here."}
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
                      : "Open Online services"}
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
                    <h2>
                      {state.nextCursor !== null
                        ? "No matches in this batch"
                        : "No photos found"}
                    </h2>
                    <p>
                      {state.nextCursor !== null
                        ? "Continue searching more photos, or adjust your filters."
                        : state.appliedQuery ||
                            new URLSearchParams(state.appliedFilters).get(
                              "semanticQuery",
                            ) ||
                            new URLSearchParams(state.appliedFilters).get(
                              "tags",
                            )
                          ? "Try a different description, tags, scores or filename."
                          : "Photos show up here as your library is scanned. Refresh to see progress."}
                    </p>
                  </div>
                )}
                <div
                  ref={grid}
                  class="images-grid collection-layout"
                  data-selecting={selection.active ? "true" : undefined}
                  data-view={layout.view.value}
                >
                  {state.items.map((image) => (
                    <button
                      key={image.id}
                      data-photo-id={image.id}
                      aria-label={takenLabel(image)}
                      type="button"
                      class={{
                        "image-tile": true,
                        selected: selection.active
                          ? selection.ids.includes(image.id)
                          : state.selected?.id === image.id,
                      }}
                      aria-pressed={
                        selection.active
                          ? selection.ids.includes(image.id)
                          : state.selected?.id === image.id
                      }
                      title={tiles ? takenLabel(image) : undefined}
                      disabled={busy}
                      onClick$={() =>
                        selection.active ? togglePhoto(image.id) : choose(image)
                      }
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
                      <span
                        class={
                          tiles
                            ? "image-item-copy image-item-copy--tiles"
                            : "image-item-copy"
                        }
                      >
                        <span class="image-item-name">
                          {takenLabel(image, !tiles)}
                        </span>
                        {layout.view.value === "detailed-list" && (
                          <>
                            <span class="image-item-meta">
                              {image.filename}
                            </span>
                            <span class="image-item-meta">
                              {image.analysis
                                ? scoreLine(image.analysis.scores)
                                : "Not analysed yet"}
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
                {(state.nextPage || state.nextCursor !== null) && (
                  <>
                    <div
                      ref={loadMoreSentinel}
                      class="images-load-sentinel"
                      aria-hidden="true"
                    />
                    <button
                      type="button"
                      class="secondary-button images-load-more"
                      disabled={state.loadingMore}
                      onClick$={() => load(true)}
                    >
                      {state.loadingMore
                        ? "Loading photos…"
                        : "Load more photos"}
                    </button>
                  </>
                )}
                {state.error && !state.setupRequired && !state.unavailable && (
                  <button
                    type="button"
                    class="secondary-button"
                    onClick$={() => load()}
                  >
                    Try again
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
