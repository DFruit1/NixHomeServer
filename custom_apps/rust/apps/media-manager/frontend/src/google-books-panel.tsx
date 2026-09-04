import { $, component$, type QRL, useStore, useTask$ } from "@builder.io/qwik";
import { api } from "./api";
import type { GoogleBooksCandidate } from "./metadata-provider-candidates";
import { RemoteArtwork } from "./remote-artwork";

export const GoogleBooksPanel = component$<{
  itemId: string;
  fallbackQuery: string;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
  onCompare$: QRL<(candidate: GoogleBooksCandidate) => void>;
}>((props) => {
  const state = useStore<{
    query: string;
    candidates: GoogleBooksCandidate[];
    loading: boolean;
    error: string;
    revision: number;
    selected?: GoogleBooksCandidate;
  }>({ query: "", candidates: [], loading: false, error: "", revision: 0 });

  useTask$(({ track }) => {
    track(() => props.itemId);
    state.query = "";
    state.candidates = [];
    state.loading = false;
    state.error = "";
    state.revision += 1;
    state.selected = undefined;
  });

  const search = $(async () => {
    const query = state.query.trim() || props.fallbackQuery.trim();
    if (!props.canEdit || !query || state.loading) return;
    const revision = state.revision + 1;
    state.revision = revision;
    state.loading = true;
    state.error = "";
    state.selected = undefined;
    try {
      const result = await api<{ results: GoogleBooksCandidate[] }>(
        "/provider-lookups/google-books/search",
        { method: "POST", body: JSON.stringify({ query }) },
      );
      if (state.revision === revision) state.candidates = result.results;
    } catch (error) {
      if (state.revision === revision)
        state.error =
          error instanceof Error
            ? error.message
            : "Google Books could not be searched.";
    } finally {
      if (state.revision === revision) state.loading = false;
    }
  });

  return (
    <section class="panel musicbrainz-panel google-books-panel">
      <div class="panel-heading">
        <div>
          <h3>Google Books lookup</h3>
        </div>
        <span class="status-badge live">Per-user API key</span>
      </div>
      <p class="quiet-copy">
        Search Google Books as a second edition source, then choose metadata
        fields and cover art independently. Configure the key in{" "}
        <a class="metadata-source-setup-link" href="?view=accounts">
          Metadata sources
        </a>
        .
      </p>
      <div class="metadata-form">
        <label class="title-input">
          <span>Title, author, or ISBN</span>
          <input
            value={state.query || props.fallbackQuery}
            maxLength={500}
            placeholder="e.g. Dune Frank Herbert"
            onInput$={(_, input) => (state.query = input.value)}
          />
        </label>
        <div class="metadata-actions">
          <button
            class="primary-button"
            type="button"
            disabled={
              !props.canEdit ||
              state.loading ||
              !(state.query.trim() || props.fallbackQuery.trim())
            }
            onClick$={search}
          >
            {state.loading ? "Looking up…" : "Find Google Books"}
          </button>
        </div>
      </div>
      {state.error && <p class="error-copy">{state.error}</p>}
      <div class="subtitle-results">
        {state.candidates.map((candidate) => (
          <article
            class="subtitle-result open-library-result"
            key={candidate.volumeId}
          >
            <div>
              <strong>
                {candidate.title}
                {candidate.year ? ` (${candidate.year})` : ""}
              </strong>
              <span>
                {candidate.authors.join(", ") || "Unknown author"}
                {candidate.publisher ? ` · ${candidate.publisher}` : ""}
                {candidate.isbn ? ` · ISBN ${candidate.isbn}` : ""}
                {candidate.pageCount
                  ? ` · ${candidate.pageCount.toLocaleString()} pages`
                  : ""}
              </span>
              {candidate.description && <p>{candidate.description}</p>}
            </div>
            <div class="open-library-result-actions">
              <button
                class="secondary-button"
                type="button"
                onClick$={() => props.onCompare$(candidate)}
              >
                Compare fields
              </button>
              {candidate.coverAvailable && (
                <button
                  class="secondary-button"
                  type="button"
                  onClick$={() => (state.selected = candidate)}
                >
                  Preview cover
                </button>
              )}
            </div>
          </article>
        ))}
        {state.candidates.length === 0 && (
          <p class="quiet-copy">
            Google Books candidates will appear here with edition, ISBN,
            publisher, and cover details.
          </p>
        )}
      </div>
      {state.selected && (
        <RemoteArtwork
          itemId={props.itemId}
          sourceUrl={`/provider-lookups/google-books/volumes/${encodeURIComponent(state.selected.volumeId)}/cover`}
          sourceLabel="Google Books"
          title={state.selected.title}
          canEdit={props.canEdit}
          mutationMode={props.mutationMode}
        />
      )}
      <p class="metadata-compatibility-note">
        Volume metadata and cover references are supplied by{" "}
        <a href="https://books.google.com/" target="_blank" rel="noreferrer">
          Google Books
        </a>
        .
      </p>
    </section>
  );
});
