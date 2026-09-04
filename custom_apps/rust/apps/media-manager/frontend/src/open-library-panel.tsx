import { $, component$, type QRL, useStore, useTask$ } from "@builder.io/qwik";
import { api } from "./api";
import { RemoteArtwork } from "./remote-artwork";

export interface OpenLibraryCandidate {
  workId: string;
  editionId?: string;
  title: string;
  editionTitle?: string;
  authors: string[];
  firstPublishYear?: number;
  editionCount?: number;
  publishDate?: string;
  publishYear?: number;
  publishers: string[];
  isbn10?: string;
  isbn13?: string;
  languages: string[];
  subjects: string[];
  numberOfPages?: number;
  coverId?: number;
  coverUrl?: string;
}

interface OpenLibraryEdition {
  editionId: string;
  title: string;
  publishDate?: string;
  publishYear?: number;
  publishers: string[];
  isbn10?: string;
  isbn13?: string;
  languages: string[];
  numberOfPages?: number;
  coverId?: number;
  coverUrl?: string;
}

interface OpenLibraryEditionsResponse {
  workId: string;
  offset: number;
  limit: number;
  total: number;
  hasMore: boolean;
  results: OpenLibraryEdition[];
}

function editionCandidate(
  work: OpenLibraryCandidate,
  edition: OpenLibraryEdition,
): OpenLibraryCandidate {
  return {
    ...work,
    editionId: edition.editionId,
    editionTitle: edition.title,
    publishDate: edition.publishDate,
    publishYear: edition.publishYear,
    publishers: edition.publishers,
    isbn10: edition.isbn10,
    isbn13: edition.isbn13,
    languages: edition.languages,
    numberOfPages: edition.numberOfPages,
    coverId: edition.coverId,
    coverUrl: edition.coverUrl,
  };
}

export const OpenLibraryPanel = component$<{
  itemId: string;
  mutationMode: "read-only" | "enabled";
  query: string;
  fallbackQuery: string;
  candidates: OpenLibraryCandidate[];
  loading: boolean;
  error: string;
  canEdit: boolean;
  onQueryInput$: QRL<(value: string) => void>;
  onSearch$: QRL<() => void>;
  onCompare$: QRL<(candidate: OpenLibraryCandidate) => void>;
}>((props) => {
  const state = useStore<{
    expandedWorkId: string;
    editions: Record<string, OpenLibraryEdition[]>;
    editionTotals: Record<string, number>;
    editionHasMore: Record<string, boolean>;
    editionNextOffsets: Record<string, number>;
    editionLoading: boolean;
    editionError: string;
    editionRevision: number;
    selectedCoverId: number;
    selectedCoverTitle: string;
  }>({
    expandedWorkId: "",
    editions: {},
    editionTotals: {},
    editionHasMore: {},
    editionNextOffsets: {},
    editionLoading: false,
    editionError: "",
    editionRevision: 0,
    selectedCoverId: 0,
    selectedCoverTitle: "",
  });
  useTask$(({ track }) => {
    track(() => props.itemId);
    state.expandedWorkId = "";
    state.editions = {};
    state.editionTotals = {};
    state.editionHasMore = {};
    state.editionNextOffsets = {};
    state.editionLoading = false;
    state.editionError = "";
    state.editionRevision += 1;
    state.selectedCoverId = 0;
    state.selectedCoverTitle = "";
  });
  const loadEditions = $(
    async (candidate: OpenLibraryCandidate, append = false) => {
      if (state.editionLoading) return;
      if (!append && state.expandedWorkId === candidate.workId) {
        state.expandedWorkId = "";
        return;
      }
      const offset = append
        ? (state.editionNextOffsets[candidate.workId] ?? 0)
        : 0;
      const revision = state.editionRevision + 1;
      state.editionRevision = revision;
      state.expandedWorkId = candidate.workId;
      state.editionLoading = true;
      state.editionError = "";
      try {
        const page = await api<OpenLibraryEditionsResponse>(
          `/provider-lookups/open-library/works/${encodeURIComponent(candidate.workId)}/editions?${new URLSearchParams({ offset: String(offset), limit: "12" })}`,
        );
        if (
          state.editionRevision !== revision ||
          state.expandedWorkId !== candidate.workId
        )
          return;
        const prior = append ? (state.editions[candidate.workId] ?? []) : [];
        state.editions[candidate.workId] = [
          ...prior,
          ...page.results.filter(
            (edition) =>
              !prior.some(
                (existing) => existing.editionId === edition.editionId,
              ),
          ),
        ];
        state.editionTotals[candidate.workId] = page.total;
        state.editionHasMore[candidate.workId] = page.hasMore;
        state.editionNextOffsets[candidate.workId] = page.offset + page.limit;
      } catch (error) {
        if (state.editionRevision === revision) {
          state.editionError =
            error instanceof Error
              ? error.message
              : "Editions could not be loaded.";
        }
      } finally {
        if (state.editionRevision === revision) state.editionLoading = false;
      }
    },
  );
  const selectCover = $((coverId: number, title: string) => {
    state.selectedCoverId = coverId;
    state.selectedCoverTitle = title;
  });

  return (
    <section class="panel musicbrainz-panel open-library-panel">
      <div class="panel-heading">
        <div>
          <h3>Open Library lookup</h3>
        </div>
        <span class="status-badge live">No account required</span>
      </div>
      <p class="quiet-copy">
        Search public book records by title, author, or ISBN, then compare the
        best edition with the current metadata. Results never change the file
        until you add fields to the draft and confirm it.
      </p>
      <div class="metadata-form">
        <label class="title-input">
          <span>Title, author, or ISBN</span>
          <input
            value={props.query || props.fallbackQuery}
            maxLength={500}
            placeholder="e.g. Dune Frank Herbert or 9780441172719"
            onInput$={(_, input) => props.onQueryInput$(input.value)}
          />
        </label>
        <div class="metadata-actions">
          <button
            class="primary-button"
            type="button"
            disabled={
              !props.canEdit ||
              props.loading ||
              !(props.query.trim() || props.fallbackQuery.trim())
            }
            onClick$={props.onSearch$}
          >
            {props.loading ? "Looking up…" : "Find books"}
          </button>
        </div>
      </div>
      {props.error && <p class="error-copy">{props.error}</p>}
      <div class="subtitle-results">
        {props.candidates.map((candidate) => (
          <article
            class="subtitle-result open-library-result"
            key={`${candidate.workId}-${candidate.editionId ?? "work"}`}
          >
            <div>
              <strong>
                {candidate.editionTitle ?? candidate.title}
                {candidate.publishYear ? ` (${candidate.publishYear})` : ""}
              </strong>
              <span>
                {candidate.authors.join(", ") || "Unknown author"}
                {candidate.publishers[0] ? ` · ${candidate.publishers[0]}` : ""}
                {candidate.isbn13
                  ? ` · ISBN ${candidate.isbn13}`
                  : candidate.isbn10
                    ? ` · ISBN ${candidate.isbn10}`
                    : ""}
              </span>
              <span class="open-library-result-facts">
                {candidate.editionCount != null
                  ? `${candidate.editionCount.toLocaleString()} editions`
                  : "Edition count unavailable"}
                {candidate.publishDate ? ` · ${candidate.publishDate}` : ""}
                {candidate.firstPublishYear &&
                candidate.firstPublishYear !== candidate.publishYear
                  ? ` · first published ${candidate.firstPublishYear}`
                  : ""}
                {candidate.numberOfPages
                  ? ` · ${candidate.numberOfPages.toLocaleString()} pages`
                  : ""}
              </span>
              {candidate.subjects.length > 0 && (
                <p>{candidate.subjects.slice(0, 5).join(" · ")}</p>
              )}
            </div>
            <div class="open-library-result-actions">
              <button
                class="secondary-button"
                type="button"
                disabled={props.loading}
                onClick$={() => props.onCompare$(candidate)}
              >
                Compare fields
              </button>
              <button
                class="secondary-button"
                type="button"
                disabled={state.editionLoading}
                onClick$={() => loadEditions(candidate)}
              >
                {state.expandedWorkId === candidate.workId
                  ? "Hide editions"
                  : "View editions"}
              </button>
              {candidate.coverId && (
                <button
                  class="secondary-button"
                  type="button"
                  onClick$={() =>
                    selectCover(
                      candidate.coverId ?? 0,
                      candidate.editionTitle ?? candidate.title,
                    )
                  }
                >
                  Preview cover
                </button>
              )}
            </div>
            {state.expandedWorkId === candidate.workId && (
              <div class="open-library-editions">
                <p class="quiet-copy">
                  {state.editionTotals[candidate.workId] ??
                    candidate.editionCount ??
                    0}{" "}
                  editions available
                </p>
                {state.editionError && (
                  <p class="error-copy">{state.editionError}</p>
                )}
                {(state.editions[candidate.workId] ?? []).map((edition) => (
                  <article class="open-library-edition" key={edition.editionId}>
                    <div>
                      <strong>{edition.title}</strong>
                      <span>
                        {edition.publishDate ?? "Publication date unavailable"}
                        {edition.publishers[0]
                          ? ` · ${edition.publishers[0]}`
                          : ""}
                        {edition.isbn13
                          ? ` · ISBN ${edition.isbn13}`
                          : edition.isbn10
                            ? ` · ISBN ${edition.isbn10}`
                            : ""}
                      </span>
                    </div>
                    <div class="open-library-result-actions">
                      <button
                        class="secondary-button"
                        type="button"
                        onClick$={() =>
                          props.onCompare$(editionCandidate(candidate, edition))
                        }
                      >
                        Compare edition
                      </button>
                      {edition.coverId && (
                        <button
                          class="secondary-button"
                          type="button"
                          onClick$={() =>
                            selectCover(edition.coverId ?? 0, edition.title)
                          }
                        >
                          Preview cover
                        </button>
                      )}
                    </div>
                  </article>
                ))}
                {state.editionLoading && (
                  <p class="quiet-copy">Loading editions…</p>
                )}
                {state.editionHasMore[candidate.workId] && (
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={state.editionLoading}
                    onClick$={() => loadEditions(candidate, true)}
                  >
                    Load more editions
                  </button>
                )}
              </div>
            )}
          </article>
        ))}
        {props.candidates.length === 0 && (
          <p class="quiet-copy">
            Candidate books will appear here with author, publisher, ISBN, and
            edition details so you can disambiguate before filling fields.
          </p>
        )}
      </div>
      {state.selectedCoverId > 0 && (
        <RemoteArtwork
          itemId={props.itemId}
          sourceUrl={`/provider-lookups/open-library/covers/${state.selectedCoverId}`}
          sourceLabel="Open Library"
          title={state.selectedCoverTitle}
          actionNoun="cover"
          canEdit={props.canEdit}
          mutationMode={props.mutationMode}
        />
      )}
      <p class="metadata-compatibility-note">
        Book data and cover identifiers are supplied by{" "}
        <a href="https://openlibrary.org/" target="_blank" rel="noreferrer">
          Open Library
        </a>
        . Lookups are intentionally limited to human-triggered searches.
      </p>
    </section>
  );
});
