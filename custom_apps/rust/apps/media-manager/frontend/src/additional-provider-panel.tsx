import { $, component$, type QRL, useStore, useTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import { RemoteArtwork } from "./remote-artwork";
import {
  PROVIDER_USAGE_GUIDES,
  ProviderUsageGuide,
} from "./provider-setup-guide";
import type {
  AdditionalProviderCandidate,
  AdditionalProviderId,
  AdditionalProviderLookupRequest,
  AdditionalProviderLookupResponse,
} from "./api-contract.generated";

export const AdditionalProviderPanel = component$<{
  provider: AdditionalProviderId;
  name: string;
  itemKey: string;
  itemId: string;
  fallbackQuery: string;
  mediaType: string;
  fallbackArtist?: string;
  providerIds: Record<string, string>;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
  publicSource?: boolean;
  inspectOnly?: boolean;
  nativeEditorUrl?: string;
  onCompare$: QRL<
    (candidate: AdditionalProviderCandidate, itemKey: string) => void
  >;
}>((props) => {
  const state = useStore({
    query: "",
    touched: false,
    revision: 0,
    loading: false,
    error: "",
    searched: false,
    results: [] as AdditionalProviderCandidate[],
    selected: undefined as AdditionalProviderCandidate | undefined,
    selectedImage: undefined as
      | AdditionalProviderCandidate["artwork"][number]
      | undefined,
    artistTouched: false,
    page: 1,
    order: "official",
    language: "eng",
    region: "us",
    artist: "",
    lastRequest: undefined as AdditionalProviderLookupRequest | undefined,
  });
  useTask$(({ track }) => {
    track(() => props.itemKey);
    track(() => props.provider);
    state.revision++;
    state.loading = false;
    state.error = "";
    state.results = [];
    state.selected = undefined;
    state.selectedImage = undefined;
    state.artistTouched = false;
    state.touched = false;
    state.searched = false;
    state.page = 1;
    state.lastRequest = undefined;
    state.artist = props.fallbackArtist ?? "";
  });
  useTask$(({ track }) => {
    const fallback = track(() => props.fallbackQuery);
    if (!state.touched) state.query = fallback;
  });
  useTask$(({ track }) => {
    const artist = track(() => props.fallbackArtist);
    if (!state.artistTouched) state.artist = artist ?? "";
  });
  const lookup = $(
    async (next?: AdditionalProviderLookupRequest, paging = false) => {
      if (state.loading || !props.canEdit) return;
      const revision = ++state.revision;
      state.loading = true;
      state.error = "";
      state.selected = undefined;
      state.selectedImage = undefined;
      if (next || !paging) state.page = 1;
      const parameters: AdditionalProviderLookupRequest = next
        ? { ...next, page: 1 }
        : paging && state.lastRequest
          ? { ...state.lastRequest, page: state.page }
          : {
              query: state.query.trim(),
              page: state.page,
              ...(props.provider === "omdb"
                ? {
                    mediaType:
                      props.mediaType === "movie"
                        ? "movie"
                        : props.mediaType === "episode"
                          ? "episode"
                          : "series",
                  }
                : {}),
              ...(props.provider === "tvdb"
                ? { order: state.order, language: state.language }
                : {}),
              ...(props.provider === "audnexus"
                ? { region: state.region }
                : {}),
              ...(state.artist ? { artist: state.artist } : {}),
            };
      try {
        const response = await api<AdditionalProviderLookupResponse>(
          `/provider-lookups/${props.provider}/${parameters.id ? "details" : "search"}`,
          { method: "POST", body: JSON.stringify(parameters) },
        );
        if (revision === state.revision) {
          state.results = response.results;
          state.lastRequest = parameters;
          state.searched = true;
        }
      } catch (error) {
        if (revision === state.revision) state.error = readableError(error);
      } finally {
        if (revision === state.revision) state.loading = false;
      }
    },
  );
  return (
    <details class="panel source-accordion">
      <summary class="source-accordion-summary">
        <span class="source-accordion-title">{props.name}</span>
        <span
          class={`status-badge ${props.publicSource ? "access-free" : "access-key"}`}
        >
          {props.publicSource ? "No setup" : "API key"}
        </span>
        <span class="source-accordion-chevron">
          <Icon name="chevron-down" size={16} />
        </span>
      </summary>
      <div class="source-accordion-body">
        {!props.publicSource && (
          <p class="quiet-copy">
            <a href="?view=accounts">Configure {props.name} in Accounts</a>
          </p>
        )}
        <ProviderUsageGuide providerId={props.provider} />
        <div class="metadata-form">
          <label class="source-query-input">
            <span>
              {PROVIDER_USAGE_GUIDES[props.provider]?.queryLabel ??
                "Search title"}
            </span>
            <input
              value={state.query}
              maxLength={500}
              placeholder={
                PROVIDER_USAGE_GUIDES[props.provider]?.queryPlaceholder
              }
              onInput$={(_, el) => {
                state.query = el.value;
                state.touched = true;
              }}
            />
          </label>
          {props.provider === "tvdb" && (
            <>
              <label>
                <span>Episode order</span>
                <select
                  value={state.order}
                  onChange$={(_, el) => (state.order = el.value)}
                >
                  <option value="official">Aired / official</option>
                  <option value="dvd">DVD</option>
                  <option value="absolute">Absolute</option>
                </select>
              </label>
              <label>
                <span>Language</span>
                <input
                  value={state.language}
                  maxLength={3}
                  onInput$={(_, el) => (state.language = el.value)}
                />
              </label>
            </>
          )}
          {props.provider === "audnexus" && (
            <label>
              <span>Region</span>
              <select
                value={state.region}
                onChange$={(_, el) => (state.region = el.value)}
              >
                {[
                  "us",
                  "uk",
                  "au",
                  "ca",
                  "de",
                  "fr",
                  "in",
                  "it",
                  "jp",
                  "es",
                ].map((region) => (
                  <option key={region} value={region}>
                    {region.toUpperCase()}
                  </option>
                ))}
              </select>
            </label>
          )}
          {["discogs", "theaudiodb"].includes(props.provider) && (
            <label>
              <span>Artist</span>
              <input
                value={state.artist}
                maxLength={200}
                onInput$={(_, el) => {
                  state.artist = el.value;
                  state.artistTouched = true;
                }}
              />
            </label>
          )}
          <button
            class="primary-button"
            type="button"
            disabled={state.loading || !props.canEdit || !state.query.trim()}
            onClick$={() => lookup()}
          >
            {state.loading ? "Looking up…" : `Find ${props.name}`}
          </button>
        </div>
        {state.error && (
          <p class="error-copy" role="alert">
            {state.error}
          </p>
        )}
        {state.searched && !state.loading && !state.results.length && (
          <p class="quiet-copy">No matching records.</p>
        )}
        <div class="subtitle-results">
          {state.results.map((candidate) => (
            <article
              class="subtitle-result open-library-result provider-lookup-result"
              key={`${candidate.provider}:${candidate.id}`}
            >
              <div>
                <strong>{candidate.title}</strong>
                <span>{candidate.subtitle}</span>
                {Object.keys(candidate.evidence).length > 0 && (
                  <dl>
                    {Object.entries(candidate.evidence).map(
                      ([label, value]) => (
                        <div key={label}>
                          <dt>{label}</dt>
                          <dd>{value}</dd>
                        </div>
                      ),
                    )}
                  </dl>
                )}
              </div>
              <div class="open-library-result-actions">
                {candidate.next ? (
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={state.loading}
                    onClick$={() =>
                      lookup({
                        ...candidate.next,
                        order: state.order,
                        language: state.language,
                        region: state.region,
                      })
                    }
                  >
                    {candidate.next.mediaType === "page"
                      ? "More episodes"
                      : "View details"}
                  </button>
                ) : (
                  !props.inspectOnly &&
                  (Object.keys(candidate.fields).length > 0 ||
                    Object.keys(candidate.providerIds).length > 0) && (
                    <button
                      class="secondary-button"
                      type="button"
                      disabled={!props.canEdit}
                      onClick$={() =>
                        props.onCompare$(candidate, props.itemKey)
                      }
                    >
                      Compare fields
                    </button>
                  )
                )}
                {!!candidate.artwork.length && (
                  <button
                    class="secondary-button"
                    type="button"
                    onClick$={() => {
                      state.selected = candidate;
                      state.selectedImage = undefined;
                    }}
                  >
                    Choose artwork
                  </button>
                )}
              </div>
            </article>
          ))}
        </div>
        {props.inspectOnly && (
          <p class="quiet-copy">
            Feed and episode changes belong in Audiobookshelf.
            {props.nativeEditorUrl && (
              <>
                {" "}
                <a
                  href={props.nativeEditorUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  Open native editor
                </a>
              </>
            )}
          </p>
        )}
        {state.selected && (
          <div class="metadata-actions">
            {state.selected.artwork.map((image, index) => (
              <button
                class="secondary-button"
                type="button"
                key={image.sourceUrl}
                onClick$={() => (state.selectedImage = image)}
              >
                Preview {image.role}
                {image.language ? ` (${image.language})` : ""} {index + 1}
              </button>
            ))}
          </div>
        )}
        {state.selectedImage && (
          <RemoteArtwork
            itemId={props.itemId}
            sourceUrl={state.selectedImage.sourceUrl}
            role={state.selectedImage.role}
            sourceLabel={props.name}
            title={`${state.selected?.title} · ${state.selectedImage.role}`}
            canEdit={props.canEdit && !!props.itemId}
            mutationMode={props.mutationMode}
          />
        )}
        {props.provider === "tvdb" && (
          <p class="quiet-copy">
            Metadata provided by{" "}
            <a href="https://thetvdb.com/" target="_blank" rel="noreferrer">
              TheTVDB
            </a>
            .
          </p>
        )}
        {state.lastRequest?.id && (
          <button
            class="secondary-button"
            type="button"
            disabled={state.loading}
            onClick$={() => lookup()}
          >
            Back to search
          </button>
        )}
        {[
          "omdb",
          "tvdb",
          "wikidata",
          "discogs",
          "comic-vine",
          "isbndb",
        ].includes(props.provider) &&
          !(props.provider === "tvdb" && state.lastRequest?.id) && (
            <div class="metadata-actions">
              <button
                class="secondary-button"
                type="button"
                disabled={state.page <= 1 || state.loading}
                onClick$={() => {
                  state.page--;
                  lookup(undefined, true);
                }}
              >
                Previous page
              </button>
              <span>Page {state.page}</span>
              <button
                class="secondary-button"
                type="button"
                disabled={
                  state.page >= 100 ||
                  state.loading ||
                  state.results.length < 10
                }
                onClick$={() => {
                  state.page++;
                  lookup(undefined, true);
                }}
              >
                Next page
              </button>
            </div>
          )}
      </div>
    </details>
  );
});
