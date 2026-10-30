import type {
  MetadataHealthIssue,
  MetadataHealthResult,
  MetadataObservation,
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
  rootId: string;
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
              {props.primary.implementationStatus === "active" ? (
                <>
                  Use {props.primary.name} in{" "}
                  <a
                    href={`?view=library&root=${encodeURIComponent(props.rootId)}&item=${encodeURIComponent(props.itemId)}`}
                  >
                    this item's metadata tools
                  </a>{" "}
                  to select the correct edition, artwork or subtitle.
                </>
              ) : (
                <>
                  {props.primary.name} is planned. Its adapter is not available
                  yet.
                </>
              )}
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
                    {provider.implementationStatus === "active" && (
                      <a
                        href={`?view=library&root=${encodeURIComponent(props.rootId)}&item=${encodeURIComponent(props.itemId)}`}
                      >
                        Use in metadata tools
                      </a>
                    )}
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

interface HealthIssueEntry {
  issue: MetadataHealthIssue;
  target: MetadataHealthResult;
}

interface GroupedIssue {
  key: string;
  issue: MetadataHealthIssue;
  entries: HealthIssueEntry[];
}

const ALBUM_HEALTH_FIELDS = new Set([
  "authors",
  "narrators",
  "series",
  "year",
  "language",
]);

type AlbumTarget = { rootId: string; path: string };
type ApplyHealthValue = QRL<
  (
    value: unknown,
    origin: "Current" | "Proposed",
    issue: MetadataHealthIssue,
    target: MetadataHealthResult,
    album?: AlbumTarget,
  ) => Promise<boolean>
>;

function groupIssues(results: MetadataHealthResult[]): GroupedIssue[] {
  const grouped = new Map<string, GroupedIssue>();
  for (const target of results) {
    for (const issue of target.health) {
      const key = JSON.stringify([
        issue.field && "currentValue" in issue ? issue.field : issue.code,
        issue.field ?? null,
      ]);
      let group = grouped.get(key);
      if (!group) {
        group = { key, issue, entries: [] };
        grouped.set(key, group);
      }
      group.entries.push({ issue, target });
    }
  }
  return [...grouped.values()];
}

function distinctValues(entries: HealthIssueEntry[], proposed: boolean) {
  const values = new Map<string, { value: unknown; sources: string[] }>();
  for (const { issue } of entries) {
    const candidates = proposed
      ? (issue.proposedValues ?? [])
      : [{ value: issue.currentValue, sources: issue.currentSources ?? [] }];
    for (const candidate of candidates) {
      const key = displayValue(candidate.value);
      const previous = values.get(key);
      values.set(key, {
        value: candidate.value,
        sources: [
          ...new Set([...(previous?.sources ?? []), ...candidate.sources]),
        ],
      });
    }
  }
  return [...values.values()];
}

const HealthDecisionRow = component$<{
  entries: HealthIssueEntry[];
  album?: AlbumTarget;
  showFile: boolean;
  canEdit: boolean;
  applying: boolean;
  onApply$: ApplyHealthValue;
}>((props) => {
  const queuedValue = useSignal("");
  const { issue, target } = props.entries[0];
  const field = issue.field ?? "";
  const editable =
    props.canEdit && isSettableField(field) && target.mediaKind !== "podcast";
  const currents = distinctValues(props.entries, false);
  const proposals = distinctValues(props.entries, true);
  const apply$ = $(async (value: unknown, origin: "Current" | "Proposed") => {
    if (await props.onApply$(value, origin, issue, target, props.album))
      queuedValue.value = `Queued: ${displayValue(value)}`;
  });
  const valueButton = (value: unknown, origin: "Current" | "Proposed") =>
    editable ? (
      <button
        type="button"
        class="health-value-set"
        disabled={props.applying}
        title={`Set this ${origin.toLowerCase()} value for “${field}”`}
        onClick$={() => apply$(value, origin)}
      >
        <span>{renderValue(value)}</span>
        <span class="health-value-action">Use {origin.toLowerCase()}</span>
      </button>
    ) : (
      <p class="health-value-text">{renderValue(value)}</p>
    );
  return (
    <tr>
      {props.showFile && (
        <th scope="row">
          <a
            class="health-review-link"
            href={`?view=library&root=${encodeURIComponent(target.rootId)}&item=${encodeURIComponent(target.itemId)}`}
          >
            <span title={target.relativePath}>
              {target.relativePath.split("/").at(-1)}
            </span>
          </a>
        </th>
      )}
      <td class="health-value">
        {currents.length > 1 && <small>Varies by file</small>}
        {currents.map((candidate, index) => (
          <div class="health-candidate" key={index}>
            {valueButton(candidate.value, "Current")}
            {!!candidate.sources.length && (
              <small>{candidate.sources.join(" · ")}</small>
            )}
          </div>
        ))}
      </td>
      <td class="health-value">
        {proposals.length ? (
          proposals.map((candidate, index) => (
            <div class="health-candidate" key={index}>
              {valueButton(candidate.value, "Proposed")}
            </div>
          ))
        ) : (
          <p class="health-no-proposal">???</p>
        )}
        {queuedValue.value && (
          <p class="health-queued-value" role="status">
            {queuedValue.value}
          </p>
        )}
      </td>
      <td class="health-provenance">
        {[
          ...new Set(
            props.entries.map(({ issue }) => proposedProvenance(issue)),
          ),
        ].map((reason) => (
          <p key={reason}>{reason}</p>
        ))}
      </td>
    </tr>
  );
});

const HealthIssueReview = component$<{
  group: HealthGroup;
  grouped: GroupedIssue;
  providers: ProviderDefinition[];
  canEdit: boolean;
  applying: boolean;
  selectedOnline?: { value: unknown; source: string };
  onApply$: ApplyHealthValue;
  onLookup$: QRL<
    (
      issue: MetadataHealthIssue,
      target: MetadataHealthResult,
      primary: ProviderDefinition,
    ) => void
  >;
}>((props) => {
  const individually = useSignal(false);
  const { issue, entries } = props.grouped;
  const target = entries[0].target;
  const field = issue.field ?? "";
  const compares = Boolean(field) && "currentValue" in issue;
  const albumField =
    Boolean(props.group.album) &&
    ALBUM_HEALTH_FIELDS.has(field) &&
    ["audiobook", "music"].includes(target.mediaKind);
  const album =
    albumField && !individually.value
      ? { rootId: props.group.rootId, path: props.group.album! }
      : undefined;
  const primary = compares
    ? candidateSources(props.providers, target.mediaKind, field)[0]
    : undefined;
  const files = [
    ...new Set(
      entries.flatMap(({ issue: entryIssue, target: entryTarget }) =>
        entryIssue.affectedFiles?.length
          ? entryIssue.affectedFiles
          : [entryTarget.relativePath.split("/").at(-1)!],
      ),
    ),
  ];
  const count = Math.max(
    files.length,
    ...entries.map(({ issue }) => issue.affectedFileCount ?? 0),
  );
  return (
    <section class="health-result-issue">
      <div class="health-comparison">
        <div class="health-reason">
          <h4>{issue.title}</h4>
          {!compares && <p>{issue.message}</p>}
        </div>
        {compares && (
          <>
            {albumField && (
              <div class="health-album-scope">
                <label>
                  <input
                    type="checkbox"
                    checked={individually.value}
                    disabled={props.applying}
                    onChange$={(_, input) =>
                      (individually.value = input.checked)
                    }
                  />
                  Edit files individually
                </label>
                <p>
                  {album
                    ? "One value for this folder and its files. Individual overrides take priority; embedded tags are retained."
                    : "File choices override the album in Media Manager. Other apps continue to read the album sidecar."}
                </p>
              </div>
            )}
            <table
              class={{
                "health-issue-table": true,
                "health-issue-table-files": !album && entries.length > 1,
              }}
            >
              <colgroup>
                {!album && entries.length > 1 && (
                  <col class="health-file-column" />
                )}
                <col class="health-current-column" />
                <col class="health-proposed-column" />
                <col />
              </colgroup>
              <caption class="sr-only">{issue.title}</caption>
              <thead>
                <tr>
                  {!album && entries.length > 1 && <th scope="col">File</th>}
                  <th scope="col">Current</th>
                  <th scope="col">Proposed</th>
                  <th scope="col" class="health-reason-heading">
                    Reason
                  </th>
                </tr>
              </thead>
              <tbody>
                {album ? (
                  <HealthDecisionRow
                    key="album"
                    entries={entries}
                    album={album}
                    showFile={false}
                    canEdit={props.canEdit}
                    applying={props.applying}
                    onApply$={props.onApply$}
                  />
                ) : (
                  entries.map((entry) => (
                    <HealthDecisionRow
                      key={entry.target.itemId}
                      entries={[entry]}
                      showFile={entries.length > 1}
                      canEdit={props.canEdit}
                      applying={props.applying}
                      onApply$={props.onApply$}
                    />
                  ))
                )}
              </tbody>
            </table>
            {!albumField &&
              ["audiobook", "music"].includes(target.mediaKind) &&
              props.canEdit && (
                <p class="health-file-scope">
                  File choices override the album in Media Manager. Other apps
                  continue to read the album sidecar.
                </p>
              )}
            {props.selectedOnline && (
              <div class="health-online-selection" role="status">
                <span class="health-value-label">Selected online value</span>
                <p class="health-value-text">
                  {renderValue(props.selectedOnline.value)}
                </p>
                <small>{props.selectedOnline.source}</small>
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
                  onClick$={() => props.onLookup$(issue, target, primary)}
                >
                  Find from External Providers
                </button>
              </p>
            )}
          </>
        )}
      </div>
      {count === 1 ? (
        <p class="health-file-details">Affects 1 file: {files[0]}</p>
      ) : (
        <details class="health-file-details">
          <summary>Affects {count} files</summary>
          <p>
            {files.slice(0, MAX_GROUPED_FILES).join(", ")}
            {count > MAX_GROUPED_FILES ? "…" : ""}
          </p>
        </details>
      )}
    </section>
  );
});

const HealthArtwork = component$<{ itemId: string }>((props) => {
  const failed = useSignal(false);
  return (
    <div class="health-result-art" aria-hidden="true" hidden={failed.value}>
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
    rootId: string;
    query: string;
    selectionKey: string;
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
      target: MetadataHealthResult,
      album?: AlbumTarget,
    ) => {
      if (!props.canEdit || applyingValue.value) return false;
      const field = issue.field ?? "";
      if (!field || !isSettableField(field)) return false;
      if (isUnset(value)) {
        if (
          typeof window !== "undefined" &&
          !window.confirm(
            `The ${origin.toLowerCase()} value is not set. Setting it will clear the “${field}” field for ${album ? "this album" : "this file"}. Continue?`,
          )
        )
          return false;
      }
      applyingValue.value = true;
      feedback.error = "";
      feedback.notice = "";
      try {
        const endpoint = album
          ? `/folders/metadata?rootId=${encodeURIComponent(album.rootId)}&relativePath=${encodeURIComponent(album.path)}`
          : `/items/${encodeURIComponent(target.itemId)}/metadata`;
        const details = await api<Record<string, unknown>>(endpoint);
        const fields = sidecarFieldsFromMetadata(details, field, value);
        if (["audiobook", "music"].includes(target.mediaKind))
          fields.mediaType = target.mediaKind;
        const fileOnly =
          !album && ["audiobook", "music"].includes(target.mediaKind);
        if (fileOnly) {
          const existing = (
            details.observations as MetadataObservation[] | undefined
          )?.find((observation) => observation.label === "File sidecar");
          fields.overrideFields = [
            ...new Set([
              ...Object.keys(existing?.fields ?? {}).filter(isSettableField),
              field,
            ]),
          ];
        }
        const preview = await api<MutationPreview>(
          album
            ? `/folders/metadata/sidecar?rootId=${encodeURIComponent(album.rootId)}&relativePath=${encodeURIComponent(album.path)}`
            : `/items/${encodeURIComponent(target.itemId)}/metadata/sidecar`,
          {
            method: "POST",
            body: JSON.stringify({
              ...fields,
              fileOnly,
            }),
          },
        );
        await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
          method: "POST",
          headers: { "if-match": `"${preview.digest}"` },
        });
        feedback.notice = `The ${origin.toLowerCase()} “${field}” value was queued for ${album ? "this album" : "this file"}. See Activity to revisit the decision.`;
        return true;
      } catch (error) {
        feedback.error = readableError(error);
        return false;
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
                {groupIssues(group.results).map((grouped) => (
                  <HealthIssueReview
                    key={`${group.key}-${grouped.key}`}
                    group={group}
                    grouped={grouped}
                    providers={providerCatalog.providers}
                    canEdit={Boolean(props.canEdit)}
                    applying={applyingValue.value}
                    selectedOnline={
                      onlineSelections[`${group.key}:${grouped.key}`]
                    }
                    onApply$={applyValue$}
                    onLookup$={(issue, target, primary) => {
                      providersDialogFor.value = {
                        issue,
                        mediaKind: target.mediaKind,
                        primary,
                        itemId: target.itemId,
                        rootId: target.rootId,
                        query: groupHeading(group).text,
                        selectionKey: `${group.key}:${grouped.key}`,
                      };
                    }}
                  />
                ))}
              </div>
              {group.results.length > 1 && (
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
          rootId={providersDialogFor.value.rootId}
          query={providersDialogFor.value.query}
          onSelect$={(value, source) => {
            const active = providersDialogFor.value;
            if (!active) return;
            onlineSelections[active.selectionKey] = { value, source };
          }}
          onClose$={() => (providersDialogFor.value = null)}
        />
      )}
    </section>
  );
});
