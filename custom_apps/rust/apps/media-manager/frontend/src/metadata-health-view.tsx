import { $, component$, useSignal, useStore, useTask$ } from "@builder.io/qwik";
import { api, ApiError } from "./api";

interface HealthRoot {
  id: string;
  label: string;
}

interface MetadataHealthIssue {
  code: string;
  severity: "info" | "warning" | "error";
  field?: string;
  title: string;
  message: string;
  sources: string[];
}

interface MetadataHealthResult {
  itemId: string;
  rootId: string;
  relativePath: string;
  mediaKind: string;
  health: MetadataHealthIssue[];
}

interface MetadataIssuesEnvelope {
  rootId: string;
  results: MetadataHealthResult[];
  inspectedItems: number;
  issueCount: number;
  severityCounts: Record<"error" | "warning" | "info", number>;
  nextCursor?: string;
}

const HealthIcon = component$<{
  name: "alert" | "arrow" | "check" | "library" | "tag";
  size?: number;
}>((props) => {
  const paths = {
    alert: ["M12 4 3 20h18z", "M12 9v4", "M12 17h.01"],
    arrow: ["M5 12h14", "m14 7 5 5-5 5"],
    check: ["m5 12 4 4L19 6"],
    library: ["M4 5h5l2 2h9v12H4z", "M4 9h16"],
    tag: ["M20 13 13 20 4 11V4h7z", "M8.5 8.5h.01"],
  };
  return (
    <svg
      aria-hidden="true"
      class="icon"
      width={props.size ?? 20}
      height={props.size ?? 20}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      {paths[props.name].map((path) => (
        <path d={path} key={path} />
      ))}
    </svg>
  );
});

const HealthLoadingState = component$(() => (
  <div class="loading-grid" aria-label="Loading metadata health">
    <span />
    <span />
    <span />
    <span />
  </div>
));

export const MetadataHealthView = component$<{
  roots: HealthRoot[];
  initialRootId?: string;
}>((props) => {
  const initialRoot =
    props.roots.find((root) => root.id === props.initialRootId) ??
    props.roots[0];
  const inbox = useStore({
    rootId: initialRoot?.id ?? "",
    results: [] as MetadataHealthResult[],
    inspectedItems: 0,
    issueCount: 0,
    errorCount: 0,
    warningCount: 0,
    infoCount: 0,
    nextCursor: "",
    loading: true,
    loadingMore: false,
    error: "",
  });
  const requestRevision = useSignal(0);

  const replacePage = $(async (rootId: string) => {
    const revision = ++requestRevision.value;
    inbox.results = [];
    inbox.inspectedItems = 0;
    inbox.issueCount = 0;
    inbox.errorCount = 0;
    inbox.warningCount = 0;
    inbox.infoCount = 0;
    inbox.nextCursor = "";
    inbox.loadingMore = false;
    inbox.error = "";
    if (!rootId) {
      inbox.loading = false;
      return;
    }
    inbox.loading = true;
    try {
      const page = await api<MetadataIssuesEnvelope>(
        `/metadata/issues?rootId=${encodeURIComponent(rootId)}&pageSize=20`,
      );
      if (revision !== requestRevision.value) return;
      inbox.results = page.results;
      inbox.inspectedItems = page.inspectedItems;
      inbox.issueCount = page.issueCount;
      inbox.errorCount = page.severityCounts.error;
      inbox.warningCount = page.severityCounts.warning;
      inbox.infoCount = page.severityCounts.info;
      inbox.nextCursor = page.nextCursor ?? "";
    } catch (error) {
      if (revision !== requestRevision.value) return;
      inbox.error = readableHealthError(error);
    } finally {
      if (revision === requestRevision.value) inbox.loading = false;
    }
  });

  useTask$(({ track }) => {
    const rootId = track(() => inbox.rootId);
    return replacePage(rootId);
  });

  const loadMore = $(async () => {
    if (!inbox.rootId || !inbox.nextCursor || inbox.loadingMore) return;
    const revision = requestRevision.value;
    const rootId = inbox.rootId;
    inbox.loadingMore = true;
    inbox.error = "";
    try {
      const page = await api<MetadataIssuesEnvelope>(
        `/metadata/issues?rootId=${encodeURIComponent(rootId)}&pageSize=20&cursor=${encodeURIComponent(inbox.nextCursor)}`,
      );
      if (revision !== requestRevision.value || rootId !== inbox.rootId) return;
      inbox.results = [...inbox.results, ...page.results];
      inbox.inspectedItems += page.inspectedItems;
      inbox.issueCount += page.issueCount;
      inbox.errorCount += page.severityCounts.error;
      inbox.warningCount += page.severityCounts.warning;
      inbox.infoCount += page.severityCounts.info;
      inbox.nextCursor = page.nextCursor ?? "";
    } catch (error) {
      if (revision !== requestRevision.value || rootId !== inbox.rootId) return;
      inbox.error = readableHealthError(error);
    } finally {
      if (revision === requestRevision.value && rootId === inbox.rootId) {
        inbox.loadingMore = false;
      }
    }
  });

  const issueLabel = `${inbox.issueCount} ${inbox.issueCount === 1 ? "issue" : "issues"}`;
  const inspectedLabel = `${inbox.inspectedItems} inspected ${inbox.inspectedItems === 1 ? "item" : "items"}`;
  return (
    <section class="health-page">
      <header class="health-toolbar">
        <div>
          <p class="eyebrow">Metadata review queue</p>
          <h2>Find the records that need attention</h2>
          <p>
            Review missing fields and disagreements between filenames, embedded
            tags, sidecars, and connected media applications.
          </p>
        </div>
        <label>
          <span>Library</span>
          <select
            aria-label="Library"
            value={inbox.rootId}
            onChange$={(_, element) => (inbox.rootId = element.value)}
          >
            {props.roots.map((root) => (
              <option key={root.id} value={root.id}>
                {root.label}
              </option>
            ))}
          </select>
        </label>
      </header>

      {!inbox.loading && inbox.rootId && !inbox.error && (
        <div class="health-summary" aria-live="polite">
          <strong>
            {issueLabel} across {inspectedLabel}
          </strong>
          <span>{inbox.errorCount} errors</span>
          <span>{inbox.warningCount} warnings</span>
          <span>{inbox.infoCount} notes</span>
        </div>
      )}

      {inbox.loading ? (
        <HealthLoadingState />
      ) : inbox.error ? (
        <div class="empty-state health-error-state" role="alert">
          <div class="empty-glyph">
            <HealthIcon name="alert" />
          </div>
          <h4>Library health could not be loaded</h4>
          <p>{inbox.error}</p>
          <button
            type="button"
            class="secondary-button health-retry"
            onClick$={() => replacePage(inbox.rootId)}
          >
            Try again
          </button>
        </div>
      ) : !inbox.rootId ? (
        <div class="empty-state">
          <div class="empty-glyph">
            <HealthIcon name="library" />
          </div>
          <h4>No media libraries are visible</h4>
          <p>
            A library will appear here after it is enabled for your account.
          </p>
        </div>
      ) : inbox.results.length === 0 ? (
        <div class="empty-state health-empty">
          <div class="empty-glyph">
            <HealthIcon name="check" />
          </div>
          <h4>No metadata issues in this page</h4>
          <p>
            The inspected records agree across their available metadata sources.
          </p>
        </div>
      ) : (
        <div class="health-results">
          {inbox.results.map((result) => {
            const filename =
              result.relativePath.split("/").at(-1) ?? result.relativePath;
            return (
              <article class="health-result" key={result.itemId}>
                <header>
                  <div>
                    <span class="health-kind">{result.mediaKind}</span>
                    <h3>{filename}</h3>
                    <p title={result.relativePath}>{result.relativePath}</p>
                  </div>
                  <a
                    class="health-review-link"
                    href={`?view=library&root=${encodeURIComponent(result.rootId)}&item=${encodeURIComponent(result.itemId)}`}
                  >
                    Review metadata <HealthIcon name="arrow" size={15} />
                  </a>
                </header>
                <div class="health-result-issues">
                  {result.health.map((issue) => (
                    <div
                      class={`health-result-issue severity-${issue.severity}`}
                      key={`${issue.code}-${issue.field ?? "record"}`}
                    >
                      <HealthIcon
                        name={issue.severity === "info" ? "tag" : "alert"}
                        size={17}
                      />
                      <div>
                        <strong>{issue.title}</strong>
                        <p>{issue.message}</p>
                        {issue.sources.length > 0 && (
                          <span>{issue.sources.join(" · ")}</span>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </article>
            );
          })}
        </div>
      )}

      {inbox.nextCursor && (
        <button
          type="button"
          class="secondary-button health-load-more"
          disabled={inbox.loadingMore}
          onClick$={loadMore}
        >
          {inbox.loadingMore ? "Inspecting…" : "Inspect next 20 items"}
        </button>
      )}
    </section>
  );
});

function readableHealthError(error: unknown): string {
  if (error instanceof ApiError) {
    return `${error.message} (${error.code}, ${error.requestId})`;
  }
  return error instanceof Error
    ? error.message
    : "The request could not be completed.";
}
