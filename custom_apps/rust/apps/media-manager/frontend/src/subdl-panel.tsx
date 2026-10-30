import { ProviderUsageGuide } from "./provider-setup-guide";
import { $, component$, useStore, useTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import type {
  AdditionalProviderCandidate,
  AdditionalProviderLookupResponse,
  MutationPreview,
  SubdlDownloadResponse,
} from "./api-contract.generated";

export const SubdlPanel = component$<{
  itemId: string;
  title: string;
  mediaType: string;
  providerIds: Record<string, string>;
  season?: number;
  episode?: number;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
}>((props) => {
  const state = useStore({
    query: "",
    queryTouched: false,
    language: "en",
    loading: false,
    error: "",
    notice: "",
    revision: 0,
    matches: [] as AdditionalProviderCandidate[],
    selected: undefined as AdditionalProviderCandidate | undefined,
    download: undefined as SubdlDownloadResponse | undefined,
    plan: undefined as MutationPreview | undefined,
  });
  useTask$(({ track }) => {
    track(() => props.itemId);
    state.revision++;
    state.query = props.title;
    state.queryTouched = false;
    state.matches = [];
    state.selected = undefined;
    state.download = undefined;
    state.plan = undefined;
    state.loading = false;
    state.error = "";
    state.notice = "";
  });
  useTask$(({ track }) => {
    const title = track(() => props.title);
    if (!state.queryTouched) state.query = title;
  });
  const search = $(async () => {
    if (state.loading || !props.canEdit) return;
    const revision = ++state.revision;
    state.loading = true;
    state.error = "";
    state.download = undefined;
    state.plan = undefined;
    const query = state.query.trim();
    const id =
      props.providerIds.imdb ??
      (props.providerIds.tmdb ? `tmdb:${props.providerIds.tmdb}` : undefined);
    try {
      const result = await api<AdditionalProviderLookupResponse>(
        "/provider-lookups/subdl/search",
        {
          method: "POST",
          body: JSON.stringify({
            query,
            ...(query === props.title && id ? { id } : {}),
            language: state.language,
            mediaType: props.mediaType,
            season: props.season,
            episode: props.episode,
          }),
        },
      );
      if (revision === state.revision) {
        state.matches = result.results;
        state.notice = result.results.length
          ? "Check the release name and language before previewing."
          : "SubDL returned no matching subtitles.";
      }
    } catch (error) {
      if (revision === state.revision) state.error = readableError(error);
    } finally {
      if (revision === state.revision) state.loading = false;
    }
  });
  const download = $(
    async (candidate: AdditionalProviderCandidate, entry?: string) => {
      if (state.loading || !props.canEdit) return;
      const revision = ++state.revision;
      state.loading = true;
      state.error = "";
      state.plan = undefined;
      state.download = undefined;
      state.selected = candidate;
      try {
        const result = await api<SubdlDownloadResponse>(
          "/provider-lookups/subdl/download",
          { method: "POST", body: JSON.stringify({ id: candidate.id, entry }) },
        );
        if (revision === state.revision) {
          state.selected = candidate;
          state.download = result;
        }
      } catch (error) {
        if (revision === state.revision) state.error = readableError(error);
      } finally {
        if (revision === state.revision) state.loading = false;
      }
    },
  );
  const prepare = $(async () => {
    const source = state.download;
    if (!source?.content || !source.format || state.loading || !props.canEdit)
      return;
    const revision = state.revision;
    const itemId = props.itemId;
    state.loading = true;
    state.error = "";
    try {
      const plan = await api<MutationPreview>(
        `/items/${encodeURIComponent(itemId)}/subtitles/upload?${new URLSearchParams({ language: state.language, sourceProvider: "subdl", format: source.format, hearingImpaired: String(state.selected?.evidence["Hearing impaired"] === "Yes") })}`,
        {
          method: "POST",
          headers: { "content-type": "text/plain; charset=utf-8" },
          body: source.content,
        },
      );
      if (revision === state.revision) state.plan = plan;
    } catch (error) {
      if (revision === state.revision) state.error = readableError(error);
    } finally {
      if (revision === state.revision) state.loading = false;
    }
  });
  const confirm = $(async () => {
    const plan = state.plan;
    if (!plan || state.loading || props.mutationMode !== "enabled") return;
    const revision = state.revision;
    state.loading = true;
    state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(plan.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${plan.digest}"` },
      });
      if (revision === state.revision) {
        state.plan = undefined;
        state.download = undefined;
        state.notice =
          "The SubDL subtitle install was added to the mutation queue.";
      }
    } catch (error) {
      if (revision === state.revision) state.error = readableError(error);
    } finally {
      if (revision === state.revision) state.loading = false;
    }
  });
  return (
    <details class="source-accordion">
      <summary class="source-accordion-summary">
        <span class="source-accordion-title">SubDL</span>
        <span class="status-badge access-key">API key</span>
      </summary>
      <div class="source-accordion-body">
        <p class="quiet-copy">
          <a href="?view=accounts">Configure SubDL in Accounts</a>
        </p>
        <ProviderUsageGuide providerId="subdl" />
        <div class="metadata-form">
          <label>
            <span>Movie or series title</span>
            <input
              value={state.query}
              maxLength={500}
              onInput$={(_, el) => {
                state.query = el.value;
                state.queryTouched = true;
              }}
            />
          </label>
          <label>
            <span>Language code</span>
            <input
              value={state.language}
              maxLength={15}
              onInput$={(_, el) => {
                state.language = el.value;
                state.plan = undefined;
              }}
            />
          </label>
          <button
            class="primary-button"
            type="button"
            disabled={state.loading || !props.canEdit || !state.query.trim()}
            onClick$={search}
          >
            {state.loading ? "Working…" : "Find SubDL subtitles"}
          </button>
        </div>
        {state.error && (
          <p class="error-copy" role="alert">
            {state.error}
          </p>
        )}
        {state.notice && <p role="status">{state.notice}</p>}
        <div class="subtitle-results">
          {state.matches.map((candidate) => (
            <article
              class="subtitle-result provider-lookup-result"
              key={candidate.id}
            >
              <div>
                <strong>{candidate.title}</strong>
                <span>{candidate.subtitle}</span>
                <span>
                  Language: {candidate.evidence.Language} · Hearing impaired:{" "}
                  {candidate.evidence["Hearing impaired"]}
                </span>
              </div>
              <button
                class="secondary-button"
                type="button"
                disabled={state.loading || !props.canEdit}
                onClick$={() => download(candidate)}
              >
                Preview subtitle
              </button>
            </article>
          ))}
        </div>
        {state.download && !state.download.content && (
          <div>
            <p>Choose a file from this subtitle pack.</p>
            {state.download.files.map((entry) => (
              <button
                class="secondary-button"
                type="button"
                key={entry}
                disabled={state.loading}
                onClick$={() =>
                  state.selected && download(state.selected, entry)
                }
              >
                {entry}
              </button>
            ))}
          </div>
        )}
        {state.download?.content && (
          <section class="subtitle-content">
            <p>
              {state.download.cueCount} cues ·{" "}
              {state.download.format?.toUpperCase()} · {state.language}
            </p>
            <pre>{state.download.content.slice(0, 6000)}</pre>
            {!state.plan ? (
              <button
                class="primary-button"
                type="button"
                disabled={state.loading || !props.canEdit}
                onClick$={prepare}
              >
                Prepare subtitle installation
              </button>
            ) : (
              <div>
                <p>
                  Destination:{" "}
                  {state.plan.actions
                    .map(
                      (action) =>
                        action.destinationRelativePath ??
                        action.replacementRelativePath ??
                        "",
                    )
                    .filter(Boolean)
                    .join(", ")}
                </p>
                {state.plan.warnings.map((w) => (
                  <p key={w}>{w}</p>
                ))}
                <button
                  class="primary-button"
                  type="button"
                  disabled={state.loading || props.mutationMode !== "enabled"}
                  onClick$={confirm}
                >
                  Confirm subtitle installation
                </button>
              </div>
            )}
          </section>
        )}
      </div>
    </details>
  );
});
