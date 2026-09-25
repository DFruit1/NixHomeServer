import type {
  MetadataHealthIssue,
  MetadataHealthResult,
  MetadataIssuesPage as MetadataIssuesEnvelope,
  ProviderCatalogResponse,
  ProviderDefinition,
} from "./api-contract.generated";
import {
  $,
  component$,
  type QRL,
  useSignal,
  useStore,
  useResource$,
  useTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import type { IconName } from "./root-types";
import {
  candidateSources,
  sourceStatus,
  sourceStatusClass,
} from "./health-source-recommendation";

interface HealthRoot {
  id: string;
  label: string;
}

type MediaKind = MetadataHealthResult["mediaKind"];

const KIND_SYMBOLS: Record<MediaKind, { icon: IconName; label: string }> = {
  video: { icon: "video", label: "Video" },
  music: { icon: "music-note", label: "Music" },
  audiobook: { icon: "headphones", label: "Audiobook" },
  podcast: { icon: "mic", label: "Podcast" },
  book: { icon: "book", label: "Book" },
};

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

function groupHeading(group: HealthGroup): {
  text: string;
  fromFilename: boolean;
} {
  const first = group.results[0];
  if (group.album)
    return {
      text: group.album.split("/").at(-1) ?? group.album,
      fromFilename: false,
    };
  const title = first.title?.trim();
  if (title) return { text: title, fromFilename: false };
  return {
    text: first.relativePath.split("/").at(-1) ?? first.relativePath,
    fromFilename: true,
  };
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

const HealthArtwork = component$<{ itemId: string }>((props) => {
  const failed = useSignal(false);
  return (
    <div class="health-result-art" aria-hidden="true">
      {!failed.value && (
        <img
          src={`/api/v1/items/${encodeURIComponent(props.itemId)}/image`}
          alt=""
          loading="lazy"
          onError$={() => (failed.value = true)}
        />
      )}
    </div>
  );
});

const AlternativeSourcesDialog = component$<{
  issue: MetadataHealthIssue;
  mediaKind: MediaKind;
  providers: ProviderDefinition[];
  onClose$: QRL<() => void>;
}>((props) => {
  const recommended = candidateSources(
    props.providers,
    props.mediaKind,
    props.issue.field ?? "",
  );
  const primary = recommended[0];
  const alternatives = primary
    ? recommended.filter((provider) => provider.id !== primary.id)
    : recommended;
  return (
    <div class="dialog-backdrop" onClick$={props.onClose$}>
      <div
        class="dialog"
        role="dialog"
        aria-modal="true"
        aria-label="Alternative sources"
        onClick$={(event) => event.stopPropagation()}
      >
        <div class="dialog-header">
          <h3>Alternative sources</h3>
          <button
            type="button"
            class="dialog-close"
            onClick$={props.onClose$}
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <div class="dialog-body">
          <p class="dialog-context">{props.issue.title}</p>
          <ul class="health-source-list">
            {alternatives.map((provider) => {
              const status = sourceStatus(provider);
              return (
                <li key={provider.id}>
                  <div class="health-source-heading">
                    <strong>{provider.name}</strong>
                    <span class={sourceStatusClass(status)}>
                      {status.label}
                    </span>
                  </div>
                  <p>{provider.notes}</p>
                  <div class="health-source-links">
                    <a
                      href={provider.documentationUrl}
                      target="_blank"
                      rel="noreferrer"
                    >
                      Documentation
                    </a>
                    <a
                      href={provider.setupUrl}
                      target="_blank"
                      rel="noreferrer"
                    >
                      Open provider setup
                    </a>
                  </div>
                </li>
              );
            })}
          </ul>
          <a class="health-source-manage" href="?view=accounts">
            Manage metadata sources
          </a>
        </div>
      </div>
    </div>
  );
});

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
  const providerCatalog = useStore<{
    providers: ProviderDefinition[];
    loaded: boolean;
  }>({ providers: [], loaded: false });
  const alternativesFor = useSignal<{
    issue: MetadataHealthIssue;
    mediaKind: MediaKind;
  } | null>(null);

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

  useTask$(async ({ track }) => {
    track(() => inbox.results.length);
    if (providerCatalog.loaded || inbox.results.length === 0) return;
    providerCatalog.loaded = true;
    try {
      const response = await api<ProviderCatalogResponse>("/provider-accounts");
      providerCatalog.providers = response.providers;
    } catch {
      providerCatalog.providers = [];
    }
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
        {groupResults(inbox.results).map((group) => {
          const first = group.results[0];
          const kind = KIND_SYMBOLS[first.mediaKind] ?? {
            icon: "file" as IconName,
            label: first.mediaKind,
          };
          const heading = groupHeading(group);
          return (
            <article class="health-result" key={group.key}>
              <header>
                <HealthArtwork itemId={first.itemId} />
                <div class="health-result-heading">
                  <h3
                    class={{
                      "health-result-title-file": heading.fromFilename,
                    }}
                  >
                    {heading.text}
                  </h3>
                  <span
                    class="health-result-kind"
                    role="img"
                    aria-label={kind.label}
                    title={kind.label}
                  >
                    <Icon name={kind.icon} size={18} />
                  </span>
                </div>
                {group.results.length === 1 && (
                  <a
                    class="health-review-link"
                    href={`?view=library&root=${encodeURIComponent(group.rootId)}&item=${encodeURIComponent(first.itemId)}`}
                  >
                    Review metadata
                  </a>
                )}
              </header>
              <div class="health-result-issues">
                {groupIssues(group.results).map(({ key, issue }) => {
                  const field = issue.field ?? "";
                  const compares = Boolean(field) && "currentValue" in issue;
                  const sources = compares
                    ? candidateSources(
                        providerCatalog.providers,
                        first.mediaKind,
                        field,
                      )
                    : [];
                  const primary = sources[0];
                  const primaryStatus = primary ? sourceStatus(primary) : null;
                  return (
                    <section
                      class="health-result-issue"
                      key={`${group.key}-${key}`}
                    >
                      <div
                        class={{
                          "health-comparison": true,
                          "health-comparison-split": compares,
                        }}
                      >
                        <div class="health-reason">
                          <h4>{issue.title}</h4>
                          {!compares && <p>{issue.message}</p>}
                        </div>
                        {compares && (
                          <div class="health-value">
                            <span class="health-value-label">Current</span>
                            <p>{displayValue(issue.currentValue)}</p>
                            {!!issue.currentSources?.length && (
                              <small>{issue.currentSources.join(" · ")}</small>
                            )}
                          </div>
                        )}
                        {compares && (
                          <div class="health-value">
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
                            {primary && primaryStatus && (
                              <>
                                <p class="health-source">
                                  Retrieve from <strong>{primary.name}</strong>
                                  <span
                                    class={sourceStatusClass(primaryStatus)}
                                  >
                                    {primaryStatus.label}
                                  </span>
                                </p>
                                {sources.length > 1 && (
                                  <button
                                    type="button"
                                    class="health-alt-sources"
                                    onClick$={() =>
                                      (alternativesFor.value = {
                                        issue,
                                        mediaKind: first.mediaKind,
                                      })
                                    }
                                  >
                                    Alternative Sources
                                  </button>
                                )}
                              </>
                            )}
                          </div>
                        )}
                      </div>
                      {(issue.affectedFiles?.length ?? 0) > 0 && (
                        <details class="health-file-details">
                          <summary>
                            Affects{" "}
                            {issue.affectedFileCount ??
                              issue.affectedFiles!.length}{" "}
                            {(issue.affectedFileCount ??
                              issue.affectedFiles!.length) === 1
                              ? "file"
                              : "files"}
                          </summary>
                          <p>{issue.affectedFiles!.join(", ")}</p>
                        </details>
                      )}
                    </section>
                  );
                })}
              </div>
              {group.results.length === 1 ? (
                <details class="health-file-details">
                  <summary>File details</summary>
                  <p>{first.relativePath}</p>
                </details>
              ) : (
                <details class="health-file-details">
                  <summary>
                    Files in this album ({group.results.length})
                  </summary>
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
          );
        })}
      </div>
      {alternativesFor.value && (
        <AlternativeSourcesDialog
          issue={alternativesFor.value.issue}
          mediaKind={alternativesFor.value.mediaKind}
          providers={providerCatalog.providers}
          onClose$={() => (alternativesFor.value = null)}
        />
      )}
    </section>
  );
});
