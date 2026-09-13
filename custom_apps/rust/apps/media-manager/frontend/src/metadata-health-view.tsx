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

interface HealthGroup {
  key: string;
  rootId: string;
  album: string | null;
  results: MetadataHealthResult[];
}

function groupResults(results: MetadataHealthResult[]): HealthGroup[] {
  const order: string[] = [];
  const byKey = new Map<string, HealthGroup>();
  for (const result of results) {
    const album = result.albumGroup ?? null;
    const key = `${result.rootId}:${album ?? result.itemId}`;
    let group = byKey.get(key);
    if (!group) {
      group = { key, rootId: result.rootId, album, results: [] };
      byKey.set(key, group);
      order.push(key);
    }
    group.results.push(result);
  }
  return order.map((key) => byKey.get(key)!);
}

const MAX_GROUPED_FILES = 25;

interface GroupedIssue {
  key: string;
  issue: MetadataHealthIssue;
}

function groupIssues(results: MetadataHealthResult[]): GroupedIssue[] {
  const multipleFiles = results.length > 1;
  const order: string[] = [];
  const byKey = new Map<
    string,
    { issue: MetadataHealthIssue; files: Set<string>; explicitCount: number }
  >();
  for (const result of results) {
    const fileName =
      result.relativePath.split("/").at(-1) ?? result.relativePath;
    for (const issue of result.health) {
      const key = JSON.stringify([
        issue.code,
        issue.field ?? null,
        issue.currentValue ?? null,
        (issue.proposedValues ?? []).map((candidate) => candidate.value),
      ]);
      let merged = byKey.get(key);
      if (!merged) {
        merged = { issue, files: new Set(), explicitCount: 0 };
        byKey.set(key, merged);
        order.push(key);
      }
      merged.explicitCount = Math.max(
        merged.explicitCount,
        issue.affectedFileCount ?? 0,
      );
      const affected = issue.affectedFiles?.length
        ? issue.affectedFiles
        : multipleFiles
          ? [fileName]
          : [];
      for (const file of affected) merged.files.add(file);
    }
  }
  return order.map((key) => {
    const merged = byKey.get(key)!;
    const files = [...merged.files];
    if (files.length === 0 && merged.explicitCount === 0) {
      return { key, issue: merged.issue };
    }
    return {
      key,
      issue: {
        ...merged.issue,
        affectedFiles: files.slice(0, MAX_GROUPED_FILES),
        affectedFileCount: merged.explicitCount || files.length,
      },
    };
  });
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
        {groupResults(inbox.results).map((group) => (
          <article class="health-result" key={group.key}>
            <header>
              <div>
                <h3>
                  {group.album
                    ? (group.album.split("/").at(-1) ?? group.album)
                    : group.results[0].title ||
                      group.results[0].relativePath.split("/").at(-1)}
                </h3>
                <p>
                  {props.roots.find((root) => root.id === group.rootId)
                    ?.label ?? group.rootId}
                  {group.results.length > 1 &&
                    ` · album · ${group.results.length} files`}
                </p>
              </div>
              {group.results.length === 1 && (
                <a
                  class="health-review-link"
                  href={`?view=library&root=${encodeURIComponent(group.rootId)}&item=${encodeURIComponent(group.results[0].itemId)}`}
                >
                  Review metadata
                </a>
              )}
            </header>
            <div class="health-result-issues">
              {groupIssues(group.results).map(({ key, issue }) => (
                <section
                  class="health-result-issue"
                  key={`${group.key}-${key}`}
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
                  {(issue.affectedFiles?.length ?? 0) > 0 && (
                    <details class="health-file-details">
                      <summary>
                        Affects{" "}
                        {issue.affectedFileCount ?? issue.affectedFiles!.length}{" "}
                        {(issue.affectedFileCount ??
                          issue.affectedFiles!.length) === 1
                          ? "file"
                          : "files"}
                      </summary>
                      <p>{issue.affectedFiles!.join(", ")}</p>
                    </details>
                  )}
                </section>
              ))}
            </div>
            {group.results.length === 1 ? (
              <details class="health-file-details">
                <summary>File details</summary>
                <p>{group.results[0].relativePath}</p>
              </details>
            ) : (
              <details class="health-file-details">
                <summary>Files in this album ({group.results.length})</summary>
                {group.results.map((result) => (
                  <p key={result.itemId}>
                    <a
                      class="health-review-link"
                      href={`?view=library&root=${encodeURIComponent(group.rootId)}&item=${encodeURIComponent(result.itemId)}`}
                    >
                      Review
                    </a>{" "}
                    {result.relativePath}
                  </p>
                ))}
              </details>
            )}
          </article>
        ))}
      </div>
    </section>
  );
});
