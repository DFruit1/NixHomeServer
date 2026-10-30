import { $, component$, useSignal, useStore, useTask$ } from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import type {
  EyeAnalysis,
  ImmichAnalysisResponse,
  ImmichImage,
  ImmichImagePage,
  ImmichImageResponse,
} from "./api-contract.generated";
import { Icon } from "./icon";
import { LoadingState } from "./view-states";
import "./images-view.css";

const photoPath = (id: string) =>
  `/provider-lookups/immich/images/${encodeURIComponent(id)}`;
const previewUrl = (id: string) => `/api/v1${photoPath(id)}/preview`;
const tagLabel = (tag: string) => tag.replaceAll("_", " ");

export const ImagesView = component$<{ immichUrl?: string }>((props) => {
  const detail = useSignal<HTMLElement>();
  const state = useStore({
    items: [] as ImmichImage[],
    selected: undefined as ImmichImage | undefined,
    analysis: undefined as EyeAnalysis | undefined,
    checked: [] as string[],
    query: "",
    appliedQuery: "",
    nextPage: null as number | null,
    canTag: false,
    loading: true,
    loadingMore: false,
    selecting: false,
    analyzing: false,
    saving: false,
    selection: 0,
    error: "",
    detailError: "",
    setupRequired: false,
    notice: "",
    imageFailed: false,
    failedPreviews: [] as string[],
  });

  const load = $(async (more = false) => {
    if (state.loadingMore || (!state.nextPage && more)) return;
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
      const result = await api<ImmichImagePage>(
        `/provider-lookups/immich/images?${params}`,
      );
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
      state.canTag = result.canTag;
    } catch (error) {
      state.error = readableError(error);
      state.setupRequired =
        error instanceof ApiError && error.code === "immich_account_required";
    } finally {
      state.loading = false;
      state.loadingMore = false;
    }
  });
  useTask$(async () => {
    await load();
  });

  const choose = $(async (image: ImmichImage) => {
    if (state.analyzing || state.saving) return;
    const selection = ++state.selection;
    state.selected = image;
    state.analysis = undefined;
    state.checked = [];
    state.detailError = "";
    state.notice = "";
    state.imageFailed = false;
    state.selecting = true;
    if (typeof window !== "undefined" && window.innerWidth <= 920) {
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => resolve()),
      );
      detail.value?.scrollIntoView({ block: "start" });
    }
    try {
      const response = await api<ImmichImageResponse>(photoPath(image.id));
      if (selection === state.selection) state.selected = response.image;
    } catch (error) {
      if (selection === state.selection)
        state.detailError = readableError(error);
    } finally {
      if (selection === state.selection) state.selecting = false;
    }
  });

  const analyze = $(async () => {
    const image = state.selected;
    if (!image || state.analyzing || state.saving || state.selecting) return;
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
      state.checked = response.analysis.suggestions
        .filter(
          (suggestion) =>
            !state.selected?.tags.some(
              (tag) => tag.value === `EYE/${suggestion.tag}`,
            ),
        )
        .slice(0, 32)
        .map((suggestion) => suggestion.tag);
    } catch (error) {
      state.detailError = readableError(error);
    } finally {
      state.analyzing = false;
    }
  });

  const save = $(async () => {
    const image = state.selected;
    if (
      !image ||
      !state.canTag ||
      !state.checked.length ||
      state.saving ||
      state.analyzing
    )
      return;
    state.saving = true;
    state.detailError = "";
    state.notice = "";
    try {
      const response = await api<ImmichImageResponse>(
        `${photoPath(image.id)}/tags`,
        {
          method: "POST",
          body: JSON.stringify({ tags: state.checked }),
        },
      );
      if (state.selected?.id !== image.id) return;
      state.selected = response.image;
      const index = state.items.findIndex((item) => item.id === image.id);
      if (index >= 0) state.items[index] = response.image;
      state.checked = [];
      state.notice = "Tags added in Immich.";
    } catch (error) {
      state.detailError = readableError(error);
    } finally {
      state.saving = false;
    }
  });

  const busy = state.analyzing || state.saving;
  return (
    <div class="images-workspace">
      <section class="images-browser" aria-label="Immich photos">
        <form
          class="images-search"
          preventdefault:submit
          onSubmit$={() => load()}
        >
          <label for="image-search">Find a photo by filename</label>
          <div class="images-search-controls">
            <input
              id="image-search"
              type="search"
              maxLength={200}
              value={state.query}
              onInput$={(_, input) => (state.query = input.value)}
              placeholder="Search Immich filenames"
            />
            <button
              class="secondary-button"
              type="submit"
              disabled={state.loading || state.loadingMore}
            >
              Search
            </button>
          </div>
        </form>
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
              Add your Immich API key under Metadata sources → Immich, then
              return here.
            </p>
            <a class="secondary-button" href="?view=accounts">
              Open Metadata sources
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
                    ? "Try another filename."
                    : "Photos in your Immich timeline will appear here."}
                </p>
              </div>
            )}
            <div class="images-grid">
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
                  {state.failedPreviews.includes(image.id) ? (
                    <span class="image-tile-placeholder">
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
                  )}
                  <span>{image.filename}</span>
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
            {state.items.length > 0 && (
              <p class="muted images-loaded">
                {state.items.length} photos loaded
              </p>
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
      </section>

      <section
        ref={detail}
        class={{
          "image-detail": true,
          panel: true,
          "image-detail--selected": !!state.selected,
        }}
        aria-label="Selected photo"
        aria-busy={busy || state.selecting}
      >
        {state.selected ? (
          <>
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
            {state.imageFailed ? (
              <div class="images-empty" role="status">
                <Icon name="image" size={32} />
                <p>
                  The preview is unavailable. You can still refresh this photo's
                  tags.
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
                Refresh tags
              </button>
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
            <section class="image-current-tags">
              <h3>Tags in Immich</h3>
              {state.selecting ? (
                <p role="status">Loading current tags…</p>
              ) : state.selected.tags.length ? (
                <ul class="image-tag-list">
                  {state.selected.tags.map((tag) => (
                    <li key={tag.id}>{tag.value}</li>
                  ))}
                </ul>
              ) : (
                <p class="muted">No tags yet.</p>
              )}
            </section>
            {state.analysis && (
              <section class="image-analysis" aria-label="EYE analysis">
                <h3>EYE suggestions</h3>
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
                  Relative scores from EYE; higher is better. Review predictions
                  before adding tags.
                </p>
                <fieldset
                  class="image-suggestions"
                  disabled={state.saving || !state.canTag}
                >
                  <legend>Select up to 32 tags to add</legend>
                  {state.analysis.suggestions.map((suggestion) => {
                    const present = state.selected!.tags.some(
                      (tag) => tag.value === `EYE/${suggestion.tag}`,
                    );
                    return (
                      <label key={suggestion.tag}>
                        <input
                          type="checkbox"
                          checked={
                            present || state.checked.includes(suggestion.tag)
                          }
                          disabled={
                            present ||
                            (!state.checked.includes(suggestion.tag) &&
                              state.checked.length >= 32)
                          }
                          onChange$={(_, input) => {
                            state.checked = input.checked
                              ? [...state.checked, suggestion.tag]
                              : state.checked.filter(
                                  (tag) => tag !== suggestion.tag,
                                );
                          }}
                        />
                        <span>{tagLabel(suggestion.tag)}</span>
                        <small>
                          {present
                            ? "Added"
                            : `${Math.round(suggestion.confidence * 100)}%`}
                        </small>
                      </label>
                    );
                  })}
                </fieldset>
                {!state.analysis.suggestions.length && (
                  <p>No suggested tags for this photo.</p>
                )}
                {!state.canTag && (
                  <p class="muted">
                    Adding tags requires Media Manager editor access and enabled
                    changes.
                  </p>
                )}
                <button
                  type="button"
                  class="primary-button images-save"
                  disabled={!state.canTag || busy || !state.checked.length}
                  onClick$={save}
                >
                  {state.saving
                    ? "Adding tags…"
                    : `Add ${state.checked.length} ${state.checked.length === 1 ? "tag" : "tags"} to Immich`}
                </button>
                <p class="muted">
                  Added under EYE/. Existing tags and original images stay in
                  Immich.
                </p>
              </section>
            )}
          </>
        ) : (
          <div class="images-empty">
            <Icon name="image" size={36} />
            <h2>Choose a photo</h2>
            <p>
              Review EYE's tags and quality scores, then add the tags you want
              in Immich.
            </p>
          </div>
        )}
      </section>
    </div>
  );
});
