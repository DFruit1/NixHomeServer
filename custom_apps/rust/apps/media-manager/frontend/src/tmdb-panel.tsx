import { $, component$, type QRL, useSignal, useTask$ } from "@builder.io/qwik";
import type {
  TmdbCandidate,
  TmdbDetails,
} from "./metadata-provider-candidates";
import { RemoteArtwork } from "./remote-artwork";
import tmdbLogo from "./tmdb-logo.svg";

export const TmdbPanel = component$<{
  itemId: string;
  itemMediaType: string;
  season?: number;
  episode?: number;
  query: string;
  fallbackQuery: string;
  searchKind: "movie" | "tv" | "auto";
  candidates: TmdbCandidate[];
  loading: boolean;
  error: string;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
  onQuery$: QRL<(value: string) => void>;
  onKind$: QRL<(value: "movie" | "tv" | "auto") => void>;
  onSearch$: QRL<() => void>;
  onCompare$: QRL<
    (candidate: TmdbCandidate) => Promise<TmdbDetails | undefined>
  >;
}>((props) => {
  const artwork = useSignal<{ path: string; title: string }>();
  useTask$(({ track }) => {
    track(() => props.itemId);
    track(() =>
      props.candidates.map((candidate) => candidate.tmdbId).join(","),
    );
    artwork.value = undefined;
  });
  const compare = $(async (candidate: TmdbCandidate) => {
    const details = await props.onCompare$(candidate);
    if (!details) return;
    const path =
      details?.stillPath ?? details?.posterPath ?? candidate.posterPath;
    if (path)
      artwork.value = { path, title: details?.title ?? candidate.title };
  });
  return (
    <section class="panel musicbrainz-panel tmdb-panel">
      <div class="panel-heading">
        <div>
          <h3>TMDB lookup</h3>
        </div>
        <span class="status-badge live">Per-user account</span>
      </div>
      <p class="quiet-copy">
        Search a movie or series, then compare movie, series, season, or exact
        episode fields. Metadata and artwork remain separate choices. Configure
        TMDB in{" "}
        <a class="metadata-source-setup-link" href="?view=accounts">
          Metadata sources
        </a>
        .
      </p>
      {(["season", "episode"].includes(props.itemMediaType) &&
        props.season == null) ||
      (props.itemMediaType === "episode" && props.episode == null) ? (
        <p class="error-copy">
          Enter season and episode numbers before comparing an episode.
        </p>
      ) : null}
      <div class="metadata-form">
        <label class="tmdb-query-input">
          <span>Title</span>
          <input
            value={props.query || props.fallbackQuery}
            maxLength={500}
            placeholder="e.g. Arrival"
            onInput$={(_, input) => props.onQuery$(input.value)}
          />
        </label>
        <label>
          <span>Kind</span>
          <select
            value={
              ["season", "episode"].includes(props.itemMediaType)
                ? "tv"
                : props.searchKind
            }
            disabled={["season", "episode"].includes(props.itemMediaType)}
            onChange$={(_, select) =>
              props.onKind$(select.value as "movie" | "tv" | "auto")
            }
          >
            <option value="auto">Movies and television</option>
            <option value="movie">Movies</option>
            <option value="tv">Television</option>
          </select>
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
            {props.loading ? "Looking up…" : "Find matches"}
          </button>
        </div>
      </div>
      {props.error && <p class="error-copy">{props.error}</p>}
      <div class="subtitle-results">
        {props.candidates.map((candidate) => (
          <article
            class="subtitle-result"
            key={`${candidate.mediaType}-${candidate.tmdbId}`}
          >
            <div>
              <strong>
                {candidate.title}
                {candidate.year ? ` (${candidate.year})` : ""}
              </strong>
              <span>
                {candidate.mediaType === "tv" ? "Television" : "Movie"}
                {candidate.voteCount != null
                  ? ` · ${candidate.voteCount.toLocaleString()} votes`
                  : ""}
                {candidate.voteAverage != null
                  ? ` · ${candidate.voteAverage.toFixed(1)}/10`
                  : ""}
              </span>
              {candidate.overview && <p>{candidate.overview}</p>}
            </div>
            <div class="open-library-result-actions">
              <button
                class="secondary-button"
                type="button"
                disabled={
                  props.loading ||
                  (["season", "episode"].includes(props.itemMediaType) &&
                    candidate.mediaType !== "tv") ||
                  (["season", "episode"].includes(props.itemMediaType) &&
                    props.season == null) ||
                  (props.itemMediaType === "episode" && props.episode == null)
                }
                onClick$={() => compare(candidate)}
              >
                Compare fields
              </button>
              {candidate.posterPath && (
                <button
                  class="secondary-button"
                  type="button"
                  onClick$={() =>
                    (artwork.value = {
                      path: candidate.posterPath!,
                      title: candidate.title,
                    })
                  }
                >
                  Preview poster
                </button>
              )}
            </div>
          </article>
        ))}
        {props.candidates.length === 0 && (
          <p class="quiet-copy">
            Candidate titles will appear here with year, popularity, and
            summary.
          </p>
        )}
      </div>
      {artwork.value && (
        <RemoteArtwork
          itemId={props.itemId}
          sourceUrl={`/provider-lookups/tmdb/images/w780/${encodeURIComponent(artwork.value.path.replace(/^\//, ""))}`}
          sourceLabel="TMDB"
          title={artwork.value.title}
          canEdit={props.canEdit}
          mutationMode={props.mutationMode}
        />
      )}
      <div class="tmdb-attribution metadata-compatibility-note">
        <a
          href="https://www.themoviedb.org"
          target="_blank"
          rel="noreferrer"
          aria-label="Visit The Movie Database"
        >
          <img src={tmdbLogo} alt="TMDB" />
        </a>
        <p>
          This product uses the TMDB API but is not endorsed or certified by
          TMDB.
        </p>
      </div>
    </section>
  );
});
