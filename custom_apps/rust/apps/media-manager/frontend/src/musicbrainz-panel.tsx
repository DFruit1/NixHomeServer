import { ProviderUsageGuide } from "./provider-setup-guide";
import { component$, type QRL, useSignal, useTask$ } from "@builder.io/qwik";
import { Icon } from "./icon";
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
    <details class="musicbrainz-panel source-accordion">
      <summary class="source-accordion-summary">
        <span class="source-accordion-title">MusicBrainz</span>
        <span class="source-accordion-chevron">
          <Icon name="chevron-down" size={16} />
        </span>
      </summary>
      <div class="source-accordion-body">
        {!props.available && (
          <p class="error-copy">MusicBrainz is unavailable on this server.</p>
        )}
        <label class="source-search-option">
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
        <div class="source-search">
          <label>
            <span>Artist</span>
            <input
              value={props.artist}
              maxLength={500}
              placeholder="e.g. Nirvana"
              onInput$={(_, input) => props.onArtist$(input.value)}
            />
          </label>
          <label>
            <span>Title</span>
            <input
              value={props.title}
              maxLength={500}
              placeholder="e.g. Nevermind"
              onInput$={(_, input) => props.onTitle$(input.value)}
            />
          </label>
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
            {props.loading ? "Searching…" : "Search"}
          </button>
        </div>
        {props.error && <p class="error-copy">{props.error}</p>}
        <div class="source-results">
          {props.candidates.map((candidate) => (
            <article
              class="source-result"
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
              <div class="source-result-actions">
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
        <ProviderUsageGuide providerId="musicbrainz" />
      </div>
    </details>
  );
});
