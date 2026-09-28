import type {
  MetadataHealthIssue,
  MetadataHealthResult,
  MetadataIssuesPage as MetadataIssuesEnvelope,
  MutationPreview,
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
  useVisibleTask$,
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

function joinList(items: string[]): string {
  if (items.length === 0) return "";
  if (items.length === 1) return items[0];
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

function quotedList(items: string[]): string {
  return joinList(items.map((item) => `“${item}”`));
}

function isUnset(value: unknown): boolean {
  return displayValue(value) === "Not set";
}

function renderValue(value: unknown) {
  if (!isUnset(value)) return displayValue(value);
  return <em class="health-unset">Not set</em>;
}

function proposedProvenance(issue: MetadataHealthIssue): string {
  const proposed = issue.proposedValues ?? [];
  if (proposed.length === 0)
    return "No configured source produced a value for this field, so there is nothing to propose yet.";
  const sources = quotedList([
    ...new Set(proposed.flatMap((candidate) => candidate.sources)),
  ]);
  const sentences = [
    proposed.length > 1
      ? `These proposed values come from ${sources || "an unidentified source"}.`
      : `The proposed value comes from ${sources || "an unidentified source"}.`,
  ];
  if (proposed.length > 1) {
    sentences.push(
      "The sources disagree on this field, so check the file in Review metadata before choosing one.",
    );
  } else if (!isUnset(issue.currentValue)) {
    const current = quotedList(issue.currentSources ?? []);
    sentences.push(
      current
        ? `The current value comes from ${current} and differs from it, so confirm which one matches the file in Review metadata.`
        : "A different value is already set, so confirm which one matches the file in Review metadata.",
    );
  }
  return sentences.join(" ");
}

const SETTABLE_HEALTH_FIELDS = new Set([
  "title",
  "year",
  "series",
  "volumeNumber",
  "authors",
  "narrators",
  "language",
]);

function isSettableField(field: string): boolean {
  return SETTABLE_HEALTH_FIELDS.has(field);
}

function asStringList(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(String);
  if (typeof value === "string" && value.trim()) {
    return value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
  }
  return [];
}

function applySidecarFieldValue(
  fields: Record<string, unknown>,
  field: string,
  value: unknown,
) {
  const empty = isUnset(value);
  switch (field) {
    case "title":
    case "series":
    case "volumeNumber":
    case "language":
      if (empty) delete fields[field];
      else fields[field] = displayValue(value);
      break;
    case "authors":
    case "narrators":
      fields[field] = empty ? [] : asStringList(value);
      break;
    case "year":
      if (empty) delete fields.year;
      else fields.year = Number(value);
      break;
    default:
      break;
  }
}

function sidecarFieldsFromMetadata(
  details: Record<string, unknown>,
  field: string,
  value: unknown,
): Record<string, unknown> {
  const fields: Record<string, unknown> = {
    mediaType: details.mediaType ?? "movie",
    title: details.title ?? "",
    authors: asStringList(details.authors),
    narrators: asStringList(details.narrators),
    genres: asStringList(details.genres),
    writers: asStringList(details.writers),
    providerIds: details.providerIds ?? {},
  };
  const optional: Array<[string, unknown]> = [
    ["series", details.series],
    ["volumeNumber", details.volumeNumber],
    ["publisher", details.publisher],
    ["isbn", details.isbn],
    ["language", details.language],
    ["description", details.description],
    ["episodeTitle", details.episodeTitle],
    ["premiereDate", details.premiereDate],
    ["officialRating", details.officialRating],
    ["year", details.year],
    ["season", details.season],
    ["episode", details.episode],
    ["runtimeMinutes", details.runtimeMinutes],
    ["communityRating", details.communityRating],
  ];
  for (const [key, candidate] of optional) {
    if (candidate !== undefined && candidate !== null && candidate !== "")
      fields[key] = candidate;
  }
  applySidecarFieldValue(fields, field, value);
  return fields;
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

interface OnlineMetadataCandidate {
  title: string;
  values: Record<string, unknown>;
}

function candidateValues(
  providerId: string,
  candidate: Record<string, unknown>,
) {
  const values: Record<string, unknown> = {};
  const put = (field: string, value: unknown) => {
    if (
      value !== undefined &&
      value !== null &&
      value !== "" &&
      (!Array.isArray(value) || value.length > 0)
    )
      values[field] = value;
  };
  const first = (...keys: string[]) =>
    keys
      .map((key) => candidate[key])
      .find((value) => value != null && value !== "");
  put("title", first("title", "name", "editionTitle"));
  put("year", first("year", "publishYear", "firstPublishYear"));
  put("description", candidate.overview ?? candidate.description);
  put("authors", candidate.artist ?? candidate.authors);
  put("publisher", first("label", "publisher", "publishers"));
  if (providerId !== "tmdb")
    put("genres", first("genres", "subjects", "categories"));
  const languages = candidate.languages;
  put("language", Array.isArray(languages) ? languages[0] : candidate.language);
  put("premiereDate", first("releaseDate", "publishDate"));
  put("isbn", first("isbn", "isbn13", "isbn10"));
  const title = displayValue(values.title);
  return title === "Not set" ? undefined : { title, values };
}

const ExternalProvidersDialog = component$<{
  issue: MetadataHealthIssue;
  mediaKind: MediaKind;
  providers: ProviderDefinition[];
  primary: ProviderDefinition;
  itemId: string;
  query: string;
  onSelect$: QRL<(value: unknown, source: string) => void>;
  onClose$: QRL<() => void>;
}>((props) => {
  const state = useStore({
    loading: false,
    error: "",
    candidates: [] as OnlineMetadataCandidate[],
    query: props.query,
  });
  const recommended = candidateSources(
    props.providers,
    props.mediaKind,
    props.issue.field ?? "",
  );
  const lookupSupported = [
    "tmdb",
    "musicbrainz",
    "open-library",
    "google-books",
  ].includes(props.primary.id);
  const searchable =
    lookupSupported && props.primary.implementationStatus === "active";

  const search = $(async () => {
    if (!state.query.trim()) return;
    state.loading = true;
    state.error = "";
    state.candidates = [];
    try {
      let raw: Record<string, unknown>[] = [];
      switch (props.primary.id) {
        case "tmdb": {
          const result = await api<{ results: Record<string, unknown>[] }>(
            "/provider-lookups/tmdb/search",
            {
              method: "POST",
              body: JSON.stringify({ query: state.query, mediaType: "auto" }),
            },
          );
          raw = result.results;
          break;
        }
        case "musicbrainz": {
          const result = await api<{ candidates: Record<string, unknown>[] }>(
            `/items/${encodeURIComponent(props.itemId)}/metadata/lookup`,
            {
              method: "POST",
              body: JSON.stringify({ mode: "search", title: state.query }),
            },
          );
          raw = result.candidates;
          break;
        }
        case "open-library": {
          const result = await api<{ results: Record<string, unknown>[] }>(
            "/provider-lookups/open-library/search",
            {
              method: "POST",
              body: JSON.stringify({ query: state.query }),
            },
          );
          raw = result.results;
          break;
        }
        case "google-books": {
          const result = await api<{ results: Record<string, unknown>[] }>(
            "/provider-lookups/google-books/search",
            {
              method: "POST",
              body: JSON.stringify({ query: state.query }),
            },
          );
          raw = result.results;
          break;
        }
        default:
          throw new Error(
            `${props.primary.name} lookup is not available here.`,
          );
      }
      state.candidates = raw.flatMap((candidate) => {
        const normalized = candidateValues(props.primary.id, candidate);
        return normalized ? [normalized] : [];
      });
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });

  useVisibleTask$(() => {
    if (searchable) void search();
  });

  return (
    <div class="dialog-backdrop" onClick$={props.onClose$}>
      <div
        class="dialog health-lookup-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="Find values from external providers"
        onClick$={(event) => event.stopPropagation()}
      >
        <div class="dialog-header">
          <h3>Find from External Providers</h3>
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
          {searchable ? (
            <>
              <p class="health-lookup-note">
                Online selections are comparison aids. Use Review metadata to
                make an edit.
              </p>
              <form
                class="health-lookup-query"
                preventdefault:submit
                onSubmit$={search}
              >
                <label>
                  <span>Search {props.primary.name}</span>
                  <input
                    value={state.query}
                    maxLength={500}
                    onInput$={(_, input) => (state.query = input.value)}
                  />
                </label>
                <button
                  class="secondary-button"
                  type="submit"
                  disabled={state.loading || !state.query.trim()}
                >
                  {state.loading ? "Searching…" : "Search"}
                </button>
              </form>
              {state.loading ? (
                <p role="status" aria-busy="true">
                  Searching {props.primary.name}…
                </p>
              ) : null}
              {state.error && (
                <p class="health-lookup-error" role="alert">
                  {state.error}
                </p>
              )}
              {!state.loading &&
                !state.error &&
                state.candidates.length === 0 && (
                  <p>No matching online metadata was found.</p>
                )}
              <ul class="health-lookup-results">
                {state.candidates.map((candidate, index) => (
                  <li key={`${candidate.title}-${index}`}>
                    <strong>{candidate.title}</strong>
                    <dl>
                      {Object.entries(candidate.values).map(
                        ([field, value]) => (
                          <div key={field}>
                            <dt>{field}</dt>
                            <dd>{displayValue(value)}</dd>
                          </div>
                        ),
                      )}
                    </dl>
                    {props.issue.field &&
                    props.issue.field in candidate.values ? (
                      <button
                        type="button"
                        class="secondary-button health-lookup-select"
                        onClick$={() => {
                          props.onSelect$(
                            candidate.values[props.issue.field!],
                            props.primary.name,
                          );
                          props.onClose$();
                        }}
                      >
                        Use {props.issue.field} value
                      </button>
                    ) : (
                      <small>
                        This result has no {props.issue.field ?? "matching"}{" "}
                        value.
                      </small>
                    )}
                  </li>
                ))}
              </ul>
            </>
          ) : (
            <p class="health-lookup-note">
              {props.primary.name} is not set up yet. Configure it below to
              search online metadata for this item.
            </p>
          )}
          <ul class="health-source-list">
            {recommended.map((provider) => {
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

export const MetadataHealthView = component$<{
  roots: HealthRoot[];
  initialRootId?: string;
  canEdit?: boolean;
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
  const providersDialogFor = useSignal<{
    issue: MetadataHealthIssue;
    mediaKind: MediaKind;
    primary: ProviderDefinition;
    itemId: string;
    query: string;
  } | null>(null);
  const onlineSelections = useStore<
    Record<string, { value: unknown; source: string }>
  >({});
  const feedback = useStore({ error: "", notice: "" });
  const applyingValue = useSignal(false);

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

  const applyValue$ = $(
    async (
      value: unknown,
      origin: "Current" | "Proposed",
      issue: MetadataHealthIssue,
      itemId: string,
    ) => {
      if (!props.canEdit || applyingValue.value) return;
      const field = issue.field ?? "";
      if (!field || !isSettableField(field)) return;
      if (isUnset(value)) {
        if (
          typeof window !== "undefined" &&
          !window.confirm(
            `The ${origin.toLowerCase()} value is not set. Setting it will clear the “${field}” field for this item. Continue?`,
          )
        )
          return;
      }
      applyingValue.value = true;
      feedback.error = "";
      feedback.notice = "";
      try {
        const details = await api<Record<string, unknown>>(
          `/items/${encodeURIComponent(itemId)}/metadata`,
        );
        const fields = sidecarFieldsFromMetadata(details, field, value);
        const preview = await api<MutationPreview>(
          `/items/${encodeURIComponent(itemId)}/metadata/sidecar`,
          {
            method: "POST",
            body: JSON.stringify(fields),
          },
        );
        await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
          method: "POST",
          headers: { "if-match": `"${preview.digest}"` },
        });
        feedback.notice = `The ${origin.toLowerCase()} “${field}” value was queued for this item. See Activity to revisit the decision.`;
      } catch (error) {
        feedback.error = readableError(error);
      } finally {
        applyingValue.value = false;
      }
    },
  );

  return (
    <section
      class="health-page"
      aria-busy={inspection.loading || inbox.scanning}
    >
      {feedback.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{feedback.error}</span>
          <button
            type="button"
            aria-label="Dismiss error"
            onClick$={() => (feedback.error = "")}
          >
            ×
          </button>
        </div>
      )}
      {feedback.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{feedback.notice}</span>
        </div>
      )}
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
                  const selectedOnline =
                    onlineSelections[`${group.key}:${key}`];
                  const renderValueButton = (
                    value: unknown,
                    origin: "Current" | "Proposed",
                  ) => {
                    if (!props.canEdit || !isSettableField(field)) {
                      return (
                        <p class="health-value-text">{renderValue(value)}</p>
                      );
                    }
                    return (
                      <button
                        type="button"
                        class="health-value-set"
                        disabled={applyingValue.value}
                        title={`Set this ${origin.toLowerCase()} value for “${field}”`}
                        onClick$={() =>
                          applyValue$(value, origin, issue, first.itemId)
                        }
                      >
                        {renderValue(value)}
                      </button>
                    );
                  };
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
                        {compares && (
                          <div class="health-value">
                            <span class="health-value-label">Current</span>
                            {renderValueButton(issue.currentValue, "Current")}
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
                                  {renderValueButton(
                                    candidate.value,
                                    "Proposed",
                                  )}
                                </div>
                              ))
                            ) : (
                              <p class="health-no-proposal">{issue.message}</p>
                            )}
                            {selectedOnline && (
                              <div
                                class="health-online-selection"
                                role="status"
                              >
                                <span class="health-value-label">
                                  Selected online value
                                </span>
                                <p class="health-value-text">
                                  {renderValue(selectedOnline.value)}
                                </p>
                                <small>{selectedOnline.source}</small>
                              </div>
                            )}
                            {primary && (
                              <p class="health-source">
                                <button
                                  type="button"
                                  class="health-source-trigger"
                                  disabled={!props.canEdit}
                                  title={
                                    !props.canEdit
                                      ? "Metadata lookup requires editor access."
                                      : undefined
                                  }
                                  onClick$={() => {
                                    if (!props.canEdit) return;
                                    providersDialogFor.value = {
                                      issue,
                                      mediaKind: first.mediaKind,
                                      primary,
                                      itemId: first.itemId,
                                      query: groupHeading(group).text,
                                    };
                                  }}
                                >
                                  Find from External Providers
                                </button>
                              </p>
                            )}
                          </div>
                        )}
                        <div class="health-reason">
                          <h4>{issue.title}</h4>
                          {!compares && <p>{issue.message}</p>}
                          {compares && (
                            <div class="health-provenance">
                              <p>{proposedProvenance(issue)}</p>
                            </div>
                          )}
                        </div>
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
      {providersDialogFor.value && (
        <ExternalProvidersDialog
          issue={providersDialogFor.value.issue}
          mediaKind={providersDialogFor.value.mediaKind}
          providers={providerCatalog.providers}
          primary={providersDialogFor.value.primary}
          itemId={providersDialogFor.value.itemId}
          query={providersDialogFor.value.query}
          onSelect$={(value, source) => {
            const active = providersDialogFor.value;
            if (!active) return;
            const issueKey = JSON.stringify([
              active.issue.code,
              active.issue.field ?? null,
              active.issue.currentValue ?? null,
              (active.issue.proposedValues ?? []).map(
                (candidate) => candidate.value,
              ),
            ]);
            const group = groupResults(inbox.results).find((entry) =>
              entry.results.some((result) => result.itemId === active.itemId),
            );
            if (group)
              onlineSelections[`${group.key}:${issueKey}`] = { value, source };
          }}
          onClose$={() => (providersDialogFor.value = null)}
        />
      )}
    </section>
  );
});
