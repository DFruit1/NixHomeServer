import {
  component$,
  type QRL,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import type {
  ProviderDefinition,
  MetadataHealthResult,
} from "./api-contract.generated";
import { readableError } from "./api";
import {
  automaticHealthMatch,
  rankHealthCandidates,
  type RankedHealthMatch,
} from "./health-provider-lookup";
import type { HealthLookupSession } from "./health-lookup-session";
export type GetHealthLookupSession = QRL<() => HealthLookupSession>;

/** Suggestions stay read-only until Use proposed follows the existing plan flow. */
export const HealthAutoProposal = component$<{
  target: MetadataHealthResult;
  field: string;
  query: string;
  providers: ProviderDefinition[];
  getSession$: GetHealthLookupSession;
  onUse$: QRL<(value: unknown) => Promise<void>>;
}>((props) => {
  const state = useStore({
    loading: false,
    message: "No configured sources available.",
    candidate: undefined as RankedHealthMatch | undefined,
  });
  useVisibleTask$(({ track, cleanup }) => {
    track(() =>
      JSON.stringify([
        props.target.itemId,
        props.query,
        props.field,
        props.providers,
      ]),
    );
    let stopped = false;
    cleanup(() => {
      stopped = true;
    });
    if (!props.providers.length) return;
    state.loading = true;
    state.candidate = undefined;
    const { getSession$, providers } = props;
    const { itemId, mediaKind } = props.target;
    const field = props.field;
    const fallbackQuery = props.query;
    const load = async () => {
      try {
        const session = await getSession$();
        if (stopped) return;
        const metadata = await session.metadata(itemId);
        if (stopped) return;
        const context = { ...metadata, title: metadata.title || fallbackQuery };
        const query = String(context.title).trim();
        if (!query) {
          if (!stopped)
            state.message = "No title is available to identify a match.";
          return;
        }
        const result = await session.search(
          providers,
          mediaKind,
          field,
          itemId,
          query,
          context,
        );
        if (stopped) return;
        const assessment = automaticHealthMatch(
          rankHealthCandidates(result.candidates, result.context, field),
          field,
          result,
        );
        state.candidate = assessment.candidate;
        state.message = assessment.message;
        if (state.candidate && result.failures.length)
          state.candidate.confidence.reasons.push(
            `Some sources could not be checked: ${result.failures.join("; ")}`,
          );
      } catch (error) {
        if (!stopped)
          state.message = `Automatic lookup unavailable: ${readableError(error)}`;
      } finally {
        if (!stopped) state.loading = false;
      }
    };
    void load();
  });
  const proposedValue = state.candidate?.values[props.field];
  return (
    <div class="health-auto-proposal" aria-busy={state.loading}>
      {state.candidate ? (
        <>
          <button
            type="button"
            class="health-value-set"
            onClick$={() => props.onUse$(state.candidate!.values[props.field])}
          >
            <span>
              {Array.isArray(proposedValue)
                ? proposedValue.join(", ")
                : String(proposedValue)}
            </span>
            <span class="health-value-action">Use proposed</span>
          </button>
          <small>
            {state.candidate.provider.name} · {state.candidate.confidence.score}
            % estimate
          </small>
          <details class="health-lookup-details">
            <summary>Confidence evidence</summary>
            <ul>
              {state.candidate.confidence.reasons.map((reason) => (
                <li key={reason}>{reason}</li>
              ))}
            </ul>
          </details>
        </>
      ) : (
        <>
          <p
            class="health-value-text health-unset"
            aria-label="No proposed value"
          >
            ???
          </p>
          <small role="status">
            {state.loading ? "Checking external sources…" : state.message}
          </small>
        </>
      )}
    </div>
  );
});
