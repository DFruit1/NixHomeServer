import { component$, type QRL, useSignal, useTask$ } from "@builder.io/qwik";
import type {
  MusicCandidate,
  MusicLookupMode,
} from "./metadata-provider-candidates";
import { RemoteArtwork } from "./remote-artwork";

export const MusicBrainzPanel = component$<{
  itemId: string;
  available: boolean;
  fingerprintAvailable: boolean;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
  mode: MusicLookupMode;
  artist: string;
  title: string;
  candidates: MusicCandidate[];
  loading: boolean;
  error: string;
  onMode$: QRL<(value: MusicLookupMode) => void>;
  onArtist$: QRL<(value: string) => void>;
  onTitle$: QRL<(value: string) => void>;
  onSearch$: QRL<() => void>;
  onCompare$: QRL<(candidate: MusicCandidate) => void>;
}>((props) => {
  const selected = useSignal<MusicCandidate>();
  useTask$(({ track }) => {
    track(() => props.itemId);
    track(() =>
      props.candidates
        .map((candidate) => candidate.releaseId ?? candidate.releaseGroupId)
        .join(","),
    );
    selected.value = undefined;
  });
  return (
    <section class="panel musicbrainz-panel">
      <div class="panel-heading">
        <div>
          <h3>MusicBrainz lookup</h3>
        </div>
        <span class={{ "status-badge": true, live: props.available }}>
          {props.available
            ? props.fingerprintAvailable
              ? "Fingerprint ready"
              : "Search only"
            : "Unavailable"}
        </span>
      </div>
      <p class="quiet-copy">
        Match an exact MusicBrainz release, compare its fields independently,
        and optionally stage its Cover Art Archive front image. Fingerprinting
        requires an AcoustID key in{" "}
        <a class="metadata-source-setup-link" href="?view=accounts">
          Metadata sources
        </a>
        .
      </p>
      <div class="metadata-form">
        <label>
          <span>Lookup mode</span>
          <select
            value={props.mode}
            onChange$={(_, select) =>
              props.onMode$(select.value as MusicLookupMode)
            }
          >
            <option value="auto">Auto — fingerprint, then search</option>
            <option value="fingerprint" disabled={!props.fingerprintAvailable}>
              Fingerprint — match the audio
            </option>
            <option value="search">Search — artist and title</option>
          </select>
        </label>
        <label>
          <span>Artist</span>
          <input
            value={props.artist}
            maxLength={500}
            placeholder="e.g. Nirvana"
            onInput$={(_, input) => props.onArtist$(input.value)}
          />
        </label>
        <label class="title-input">
          <span>Title</span>
          <input
            value={props.title}
            maxLength={500}
            placeholder="e.g. Nevermind"
            onInput$={(_, input) => props.onTitle$(input.value)}
          />
        </label>
        <div class="metadata-actions">
          <button
            class="primary-button"
            type="button"
            disabled={
              !props.available ||
              !props.canEdit ||
              !props.itemId ||
              props.loading ||
              (props.mode === "fingerprint" && !props.fingerprintAvailable)
            }
            onClick$={props.onSearch$}
          >
            {props.loading ? "Looking up…" : "Look up release"}
          </button>
        </div>
      </div>
      {props.error && <p class="error-copy">{props.error}</p>}
      <div class="subtitle-results">
        {props.candidates.map((candidate) => (
          <article
            class="subtitle-result"
            key={candidate.releaseId ?? candidate.releaseGroupId}
          >
            <div>
              <strong>
                {candidate.artist} — {candidate.title}
              </strong>
              <span>
                {candidate.releaseType ?? "Release"} ·{" "}
                {candidate.releaseDate ?? candidate.year ?? "unknown date"}
                {candidate.country ? ` · ${candidate.country}` : ""}
                {candidate.label ? ` · ${candidate.label}` : ""}
                {candidate.catalogNumber ? ` ${candidate.catalogNumber}` : ""}
                {candidate.trackCount
                  ? ` · ${candidate.trackCount} tracks`
                  : ""}
                {candidate.packaging ? ` · ${candidate.packaging}` : ""}
                {candidate.matchMethod === "fingerprint"
                  ? " · matched by fingerprint"
                  : " · matched by search"}
              </span>
              {candidate.disambiguation && <p>{candidate.disambiguation}</p>}
            </div>
            <div class="open-library-result-actions">
              <button
                class="secondary-button"
                type="button"
                onClick$={() => props.onCompare$(candidate)}
              >
                Compare fields
              </button>
              {candidate.releaseId && (
                <button
                  class="secondary-button"
                  type="button"
                  onClick$={() => (selected.value = candidate)}
                >
                  Preview cover
                </button>
              )}
            </div>
          </article>
        ))}
        {props.candidates.length === 0 && (
          <p class="quiet-copy">
            Exact releases will appear here with date, country, barcode, label,
            catalog number, packaging, and track count.
          </p>
        )}
      </div>
      {selected.value?.releaseId && (
        <RemoteArtwork
          itemId={props.itemId}
          sourceUrl={`/provider-lookups/cover-art-archive/releases/${selected.value.releaseId}/front`}
          sourceLabel="Cover Art Archive"
          title={`${selected.value.artist} — ${selected.value.title}`}
          canEdit={props.canEdit}
          mutationMode={props.mutationMode}
        />
      )}
    </section>
  );
});
