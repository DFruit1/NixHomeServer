import type {
  MetadataHealthIssue,
  MetadataHealthResult,
  MetadataIssuesPage as MetadataIssuesEnvelope,
} from "./api-contract.generated";
import {
  $,
  component$,
  useSignal,
  useStore,
  useResource$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";

interface HealthRoot {
  id: string;
  label: string;
}

function displayValue(value: unknown): string {
  if (value == null || value === "") return "Not set";
  if (Array.isArray(value))
    return value.map(displayValue).join(", ") || "Not set";
  return typeof value === "object" ? JSON.stringify(value) : String(value);
}

export const MetadataHealthView = component$<{
  roots: HealthRoot[];
  initialRootId?: string;
}>((props) => {
  const inbox = useStore({
    rootId: props.roots.some((root) => root.id === props.initialRootId)
      ? props.initialRootId!
      : "",
    results: [] as MetadataHealthResult[],
    inspectedItems: 0,
    issueCount: 0,
    scanning: false,
    errors: [] as string[],
  });
  const requestRevision = useSignal(0);

  const inspectLibraries = $(async (rootId: string) => {
    const revision = ++requestRevision.value;
    inbox.results = [];
    inbox.inspectedItems = 0;
    inbox.issueCount = 0;
    inbox.errors = [];
    inbox.scanning = true;
    const roots = props.roots.filter((root) => !rootId || root.id === rootId);
    let index = 0;
    // Limit concurrent library scans; each root's bounded API pages stay ordered.
    await Promise.all(
      Array.from({ length: Math.min(3, roots.length) }, async () => {
        while (index < roots.length && revision === requestRevision.value) {
          const root = roots[index++];
          let cursor = "";
          const seenCursors = new Set<string>();
          try {
            do {
              const page = await api<MetadataIssuesEnvelope>(
                `/metadata/issues?rootId=${encodeURIComponent(root.id)}&pageSize=20${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
              );
              if (revision !== requestRevision.value) return;
              const nextCursor = page.nextCursor ?? "";
              if (nextCursor && seenCursors.has(nextCursor))
                throw new Error(
                  "The library returned a repeated page. Retry the inspection.",
                );
              inbox.results = [
                ...inbox.results,
                ...page.results.map((result) => ({
                  ...result,
                  rootId: root.id,
                })),
              ];
              inbox.inspectedItems += page.inspectedItems;
              inbox.issueCount += page.issueCount;
              cursor = nextCursor;
              seenCursors.add(cursor);
            } while (cursor && revision === requestRevision.value);
          } catch (error) {
            if (revision === requestRevision.value)
              inbox.errors = [
                ...inbox.errors,
                `${root.label}: ${readableError(error)}`,
              ];
          }
        }
      }),
    );
    if (revision === requestRevision.value) inbox.scanning = false;
  });

  const inspection = useResource$(({ track, cleanup }) => {
    const rootId = track(() => inbox.rootId);
    const revision = requestRevision.value + 1;
    cleanup(() => {
      if (requestRevision.value === revision) requestRevision.value++;
    });
    return inspectLibraries(rootId);
  });

  return (
    <section
      class="health-page"
      aria-busy={inspection.loading || inbox.scanning}
    >
      <div class="health-toolbar">
        <label>
          <span>Library</span>
          <select
            value={inbox.rootId}
            onChange$={(_, element) => (inbox.rootId = element.value)}
          >
            <option value="">All libraries</option>
            {props.roots.map((root) => (
              <option key={root.id} value={root.id}>
                {root.label}
              </option>
            ))}
          </select>
        </label>
        <p class="health-summary" role="status">
          {inbox.scanning
            ? `Checking libraries · ${inbox.inspectedItems} items inspected`
            : `${inbox.issueCount} ${inbox.issueCount === 1 ? "issue" : "issues"} across ${inbox.inspectedItems} inspected ${inbox.inspectedItems === 1 ? "item" : "items"}${inbox.errors.length ? " · incomplete" : ""}`}
        </p>
      </div>

      {inbox.errors.length > 0 && (
        <div class="health-error-state" role="alert">
          {inbox.errors.map((error) => (
            <p key={error}>{error}</p>
          ))}
          <button
            type="button"
            class="secondary-button health-retry"
            disabled={inbox.scanning}
            onClick$={() => inspectLibraries(inbox.rootId)}
          >
            Try again
          </button>
        </div>
      )}
      {props.roots.length === 0 ? (
        <p>No media libraries are visible.</p>
      ) : !inbox.scanning &&
        !inbox.errors.length &&
        inbox.results.length === 0 ? (
        <p class="health-empty">
          No metadata issues found in the inspected libraries.
        </p>
      ) : null}

      <div class="health-results">
        {inbox.results.map((result) => (
          <article
            class="health-result"
            key={`${result.rootId}:${result.itemId}`}
          >
            <header>
              <div>
                <h3>{result.title || result.relativePath.split("/").at(-1)}</h3>
                <p>
                  {props.roots.find((root) => root.id === result.rootId)
                    ?.label ?? result.rootId}
                </p>
              </div>
              <a
                class="health-review-link"
                href={`?view=library&root=${encodeURIComponent(result.rootId)}&item=${encodeURIComponent(result.itemId)}`}
              >
                Review metadata
              </a>
            </header>
            <div class="health-result-issues">
              {result.health.map((issue) => (
                <section
                  class="health-result-issue"
                  key={`${issue.code}-${issue.field ?? "record"}`}
                >
                  <h4>{issue.title}</h4>
                  {issue.field && "currentValue" in issue ? (
                    <div class="health-comparison">
                      <div>
                        <span class="health-value-label">Current</span>
                        <p>{displayValue(issue.currentValue)}</p>
                        {!!issue.currentSources?.length && (
                          <small>{issue.currentSources.join(" · ")}</small>
                        )}
                      </div>
                      <div>
                        <span class="health-value-label">Proposed</span>
                        {issue.proposedValues?.length ? (
                          issue.proposedValues.map((candidate, index) => (
                            <div class="health-candidate" key={index}>
                              <p>{displayValue(candidate.value)}</p>
                              <small>{candidate.sources.join(" · ")}</small>
                            </div>
                          ))
                        ) : (
                          <p class="health-no-proposal">{issue.message}</p>
                        )}
                      </div>
                    </div>
                  ) : (
                    <p>{issue.message}</p>
                  )}
                </section>
              ))}
            </div>
            <details class="health-file-details">
              <summary>File details</summary>
              <p>{result.relativePath}</p>
            </details>
          </article>
        ))}
      </div>
    </section>
  );
});
