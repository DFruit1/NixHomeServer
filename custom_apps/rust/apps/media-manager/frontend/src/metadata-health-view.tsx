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
  Slot,
  type QRL,
  useSignal,
  noSerialize,
  type NoSerialize,
  useStore,
  useResource$,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { metadataFieldLabel } from "./item-editor-helpers";
import { revealWhenMounted } from "./reveal";
import { Icon } from "./icon";
import { HealthPlayback, HealthPlayButton } from "./health-playback";
import { HealthTrackSequence } from "./health-track-sequence";
import { ComicArchiveAction } from "./comic-archive-action";
import "./health-number-table.css";
import {
  enqueueHealthWrite,
  healthValueKey,
  healthIssueKey,
  saveHealthDecision,
  withoutHealthEntry,
  type HealthChoice,
  type HealthIssueEntry,
} from "./health-decisions";
import {
  rankHealthCandidates,
  hasHealthValue,
  type HealthMatch,
} from "./health-provider-lookup";
import {
  createHealthLookupSession,
  type HealthLookupSession,
} from "./health-lookup-session";
import {
  HealthAutoProposal,
  type GetHealthLookupSession,
} from "./health-auto-proposal";
import type { IconName } from "./root-types";
import { candidateSources, sourceStatus } from "./health-source-recommendation";

import { thumbnailSizes, thumbnailSrc, thumbnailSrcset } from "./thumbnail";
interface HealthRoot {
  id: string;
  label: string;
}

type MediaKind = MetadataHealthResult["mediaKind"];

const TERMINAL_PLAN_STATES = new Set([
  "completed",
  "failed",
  "rejected",
  "expired",
]);
// Confirmed plans must settle before a later selection reads fresh metadata.
const unsettledPlans = new Set<string>();

function healthEntryId(itemId: string, issue: MetadataHealthIssue): string {
  return `${itemId}\u0000${healthIssueKey(issue)}`;
}

function hiddenIssueCount(
  results: MetadataHealthResult[],
  hidden: Record<string, boolean>,
): number {
  let count = 0;
  for (const result of results)
    for (const issue of result.health)
      if (hidden[healthEntryId(result.itemId, issue)]) count += 1;
  return count;
}

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function settleHealthPlans(): Promise<{
  failure: string;
  pending: boolean;
}> {
  let failure = "";
  for (const planId of [...unsettledPlans]) {
    let state = "";
    let detail = "";
    for (let attempt = 0; attempt < 240; attempt += 1) {
      const status = await api<{ state?: string; error?: string | null }>(
        `/plans/${encodeURIComponent(planId)}`,
      );
      state = status.state ?? "";
      detail = status.error ?? "";
      if (TERMINAL_PLAN_STATES.has(state)) break;
      await wait(500);
    }
    if (!TERMINAL_PLAN_STATES.has(state)) continue;
    unsettledPlans.delete(planId);
    if (state !== "completed" && !failure)
      failure = detail || "The metadata write failed.";
  }
  return { failure, pending: unsettledPlans.size > 0 };
}

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

function proposedProvenance(
  issue: MetadataHealthIssue,
  multipleFiles = false,
): string {
  const proposed = issue.proposedValues ?? [];
  // "No suggestion" already says this; a sentence would only repeat it.
  if (proposed.length === 0) return "";
  if (proposed.length > 1)
    return "Sources disagree; compare the attributed values before choosing.";
  const sources = quotedList([
    ...new Set(proposed.flatMap((candidate) => candidate.sources)),
  ]);
  return `Proposed from ${sources || "an unidentified source"}.`;
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

function editableHealthIssue(
  issue: MetadataHealthIssue,
  target: MetadataHealthResult,
  canEdit: boolean,
) {
  return (
    canEdit &&
    isSettableField(issue.field ?? "") &&
    target.mediaKind !== "podcast"
  );
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

const WRITE_LANGUAGE = /^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/;
const WRITE_CONTROL = /[\p{Cc}]/u;
const SUPPORTED_MEDIA_TYPES = new Set([
  "movie",
  "series",
  "season",
  "episode",
  "music",
  "audiobook",
  "book",
]);

function byteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

function writeText(value: unknown, maximum: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  if (!text || byteLength(text) > maximum) return undefined;
  if (
    [...text].some(
      (character) =>
        WRITE_CONTROL.test(character) &&
        character !== "\n" &&
        character !== "\r" &&
        character !== "\t",
    )
  )
    return undefined;
  return text;
}

function writeTextList(value: unknown, maximumItems: number): string[] {
  const items = asStringList(value)
    .map((item) => writeText(item, 500))
    .filter((item): item is string => Boolean(item));
  return items.slice(0, maximumItems);
}

function writeLanguage(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const language = value.trim().toLowerCase();
  return byteLength(language) <= 15 && WRITE_LANGUAGE.test(language)
    ? language
    : undefined;
}

function writeInteger(
  value: unknown,
  minimum: number,
  maximum: number,
): number | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  const number = typeof value === "number" ? value : Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum
    ? number
    : undefined;
}

function writeRating(value: unknown): number | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) && number >= 0 && number <= 10
    ? number
    : undefined;
}

function writeProviderIds(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const ids: Record<string, string> = {};
  for (const [key, candidate] of Object.entries(value)) {
    const id = writeText(candidate, 256);
    if (!id || !writeText(key, 64)) continue;
    ids[key] = id;
    if (Object.keys(ids).length >= 32) break;
  }
  return ids;
}

function writeSelectedText(
  field: string,
  value: unknown,
  maximum: number,
): string {
  const text = writeText(value, maximum);
  if (!text)
    throw new Error(
      `The selected ${metadataFieldLabel(field).toLowerCase()} value cannot be saved. Edit it in Review metadata and try again.`,
    );
  return text;
}

function applySidecarFieldValue(
  fields: Record<string, unknown>,
  field: string,
  value: unknown,
) {
  const empty = isUnset(value);
  switch (field) {
    case "title":
      fields.title = empty ? "" : writeSelectedText(field, value, 500);
      break;
    case "series":
      if (empty) delete fields.series;
      else fields.series = writeSelectedText(field, value, 500);
      break;
    case "volumeNumber":
      if (empty) delete fields.volumeNumber;
      else fields.volumeNumber = writeSelectedText(field, value, 32);
      break;
    case "language": {
      if (empty) {
        delete fields.language;
        break;
      }
      const language = writeLanguage(value);
      if (!language)
        throw new Error(
          "The selected language must be a code such as en or en-US. Edit it in Review metadata and try again.",
        );
      fields.language = language;
      break;
    }
    case "authors":
    case "narrators": {
      const items = empty ? [] : writeTextList(value, 32);
      if (!empty && items.length === 0)
        throw new Error(
          `The selected ${field} value cannot be saved. Edit it in Review metadata and try again.`,
        );
      fields[field] = items;
      break;
    }
    case "year": {
      if (empty) {
        delete fields.year;
        break;
      }
      const year = writeInteger(value, 1, 2100);
      if (year === undefined)
        throw new Error(
          "The selected release year must be between 1 and 2100. Edit it in Review metadata and try again.",
        );
      fields.year = year;
      break;
    }
    default:
      break;
  }
}

function sidecarFieldsFromMetadata(
  details: Record<string, unknown>,
  field: string,
  value: unknown,
): Record<string, unknown> {
  const mediaType =
    typeof details.mediaType === "string" &&
    SUPPORTED_MEDIA_TYPES.has(details.mediaType)
      ? details.mediaType
      : "movie";
  // Only forward values the write endpoint accepts. Copying an unrelated
  // invalid value must not block the field the reviewer actually chose.
  const fields: Record<string, unknown> = {
    mediaType,
    title: writeText(details.title, 500) ?? "",
    authors: writeTextList(details.authors, 32),
    narrators: writeTextList(details.narrators, 32),
    genres: writeTextList(details.genres, 64),
    writers: writeTextList(details.writers, 64),
    providerIds: writeProviderIds(details.providerIds),
  };
  const optional: Array<[string, string | number | undefined]> = [
    ["series", writeText(details.series, 500)],
    ["volumeNumber", writeText(details.volumeNumber, 32)],
    ["publisher", writeText(details.publisher, 500)],
    ["isbn", writeText(details.isbn, 64)],
    ["language", writeLanguage(details.language)],
    ["description", writeText(details.description, 20_000)],
    ["episodeTitle", writeText(details.episodeTitle, 500)],
    ["premiereDate", writeText(details.premiereDate, 10)],
    ["officialRating", writeText(details.officialRating, 64)],
    ["year", writeInteger(details.year, 1, 2100)],
    ["season", writeInteger(details.season, 0, 10_000)],
    ["episode", writeInteger(details.episode, 1, 100_000)],
    ["runtimeMinutes", writeInteger(details.runtimeMinutes, 1, 100_000)],
    ["communityRating", writeRating(details.communityRating)],
  ];
  for (const [key, candidate] of optional) {
    if (candidate !== undefined) fields[key] = candidate;
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
  const filename = first.relativePath.split("/").at(-1) ?? first.relativePath;
  return {
    text: filename.replace(/\.[^.\/]+$/, "") || filename,
    fromFilename: true,
  };
}

function renderCandidateFields(fields: [string, unknown][]) {
  return (
    <dl>
      {fields.map(([field, value]) => (
        <div key={field}>
          <dt>{field === "isbn" ? "ISBN" : metadataFieldLabel(field)}</dt>
          <dd>{displayValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}

const ExternalProvidersDialog = component$<{
  issue: MetadataHealthIssue;
  getSession$: GetHealthLookupSession;
  mediaKind: MediaKind;
  providers: ProviderDefinition[];
  primary: ProviderDefinition;
  itemId: string;
  rootId: string;
  query: string;
  queryFromFilename: boolean;
  onSelect$: QRL<(value: unknown, source: string) => void>;
  onClose$: QRL<() => void>;
}>((props) => {
  const needsClarification = useSignal(props.queryFromFilename);
  const state = useStore({
    loading: false,
    error: "",
    candidates: [] as HealthMatch[],
    query: props.query,
    context: {} as Record<string, unknown>,
    statuses: {} as Record<string, string>,
  });
  const recommended = candidateSources(
    props.providers,
    props.mediaKind,
    props.issue.field ?? "",
  );
  const searchable = recommended.length > 0;
  const searchRevision = useSignal(0);
  const search = $(async () => {
    if (!state.query.trim() || state.loading) return;
    needsClarification.value = false;
    const revision = ++searchRevision.value;
    const {
      itemId,
      query: initialQuery,
      providers,
      mediaKind,
      getSession$,
    } = props;
    const field = props.issue.field ?? "";
    const query = state.query.trim();
    state.loading = true;
    state.error = "";
    state.candidates = [];
    try {
      // Metadata supplies edition identifiers and evidence for matching.
      const session = await getSession$();
      state.context = await session.metadata(itemId);
    } catch {
      state.context = { title: initialQuery };
    }
    state.context = {
      ...state.context,
      // Prefer the item/album title when known; otherwise use the clarified
      // search title (filename stem, without extension) for matching.
      title: state.context.title || query,
    };
    const session = await getSession$();
    state.statuses = {};
    if (revision !== searchRevision.value) return;
    await session.search(
      providers,
      mediaKind,
      field,
      itemId,
      query,
      state.context,
      (candidates, provider, status) => {
        if (revision !== searchRevision.value) return;
        state.candidates = [...state.candidates, ...candidates];
        state.statuses[provider] = status;
      },
    );
    if (revision === searchRevision.value) state.loading = false;
  });

  useVisibleTask$(({ cleanup }) => {
    if (!needsClarification.value) void search();
    cleanup(() => {
      searchRevision.value++;
    });
  });

  const matches = rankHealthCandidates(
    state.candidates,
    state.context,
    props.issue.field ?? "",
  );
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
              {needsClarification.value && (
                <p class="health-lookup-note" role="status">
                  Confirm the title for this album or file before searching
                  external sources. A clear title matches the actual item more
                  accurately than a filename.
                </p>
              )}
              <p class="health-lookup-note">
                Showing matches of at least 30%, best first. Confidence is an
                evidence estimate, not a verified probability.
              </p>
              <form
                class="health-lookup-query"
                preventdefault:submit
                onSubmit$={search}
              >
                <label>
                  <span>
                    {needsClarification.value
                      ? "Title to search"
                      : "Search all sources"}
                  </span>
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
                  {state.loading
                    ? "Searching…"
                    : needsClarification.value
                      ? "Search with this title"
                      : "Search"}
                </button>
              </form>
              {state.loading ? (
                <p role="status" aria-busy="true">
                  Searching available sources…
                </p>
              ) : null}
              {state.error && (
                <p class="health-lookup-error" role="alert">
                  {state.error}
                </p>
              )}
              {!state.loading &&
                !state.error &&
                !needsClarification.value &&
                matches.length === 0 && (
                  <p>No results supply this field with at least a 30% match.</p>
                )}
              {!state.loading &&
                !state.error &&
                needsClarification.value &&
                matches.length === 0 && (
                  <p>
                    Enter or confirm the title, then search to find values that
                    belong to this item.
                  </p>
                )}
              <ul class="health-lookup-results">
                {matches.map((candidate, index) => {
                  const confidence = candidate.confidence;
                  // The title already identifies the result. Keep the requested
                  // field and edition identifiers visible; retain other detail.
                  const fields = Object.entries(candidate.values).filter(
                    ([field]) => field !== "title",
                  );
                  const primaryFields = new Set([
                    props.issue.field,
                    "authors",
                    "year",
                    "publisher",
                    "isbn",
                  ]);
                  const extra = fields.filter(
                    ([field]) => !primaryFields.has(field),
                  );
                  return (
                    <li key={`${candidate.title}-${index}`}>
                      <div class="health-provider-summary">
                        {candidate.provider.logoUrl && (
                          <img
                            src={candidate.provider.logoUrl}
                            width="24"
                            height="24"
                            alt=""
                          />
                        )}
                        <strong>{candidate.provider.name}</strong>
                        <span
                          class="health-confidence"
                          title={confidence.reasons.join("; ")}
                          tabIndex={0}
                          aria-label={`Estimated confidence ${confidence.score} percent. ${confidence.reasons.join("; ")}`}
                        >
                          {confidence.score}% estimate
                        </span>
                      </div>
                      <details class="health-lookup-details">
                        <summary>Confidence evidence</summary>
                        <ul>
                          {confidence.reasons.map((reason) => (
                            <li key={reason}>{reason}</li>
                          ))}
                        </ul>
                      </details>
                      <strong>{candidate.title}</strong>
                      {renderCandidateFields(
                        fields.filter(([field]) => primaryFields.has(field)),
                      )}
                      {extra.length > 0 && (
                        <details class="health-lookup-details">
                          <summary>More metadata</summary>
                          {renderCandidateFields(extra)}
                        </details>
                      )}
                      {props.issue.field &&
                      props.issue.field in candidate.values ? (
                        <button
                          type="button"
                          class="secondary-button health-lookup-select"
                          onClick$={async () => {
                            await props.onSelect$(
                              candidate.values[props.issue.field!],
                              candidate.provider.name,
                            );
                            await props.onClose$();
                          }}
                        >
                          Compare{" "}
                          {metadataFieldLabel(props.issue.field).toLowerCase()}
                        </button>
                      ) : (
                        <small>
                          This result has no{" "}
                          {metadataFieldLabel(
                            props.issue.field ?? "matching",
                          ).toLowerCase()}{" "}
                          value.
                        </small>
                      )}
                    </li>
                  );
                })}
              </ul>
            </>
          ) : (
            <p class="health-lookup-note">
              {props.primary.implementationStatus === "active" ? (
                <>
                  Use {props.primary.name} in Review metadata for editions,
                  artwork or subtitles.
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
            {recommended
              .filter(
                (provider) =>
                  state.statuses[provider.id] ||
                  !matches.some(
                    (candidate) => candidate.provider.id === provider.id,
                  ),
              )
              .map((provider) => {
                const notSetUp =
                  provider.account.state !== "configured" &&
                  provider.account.state !== "notRequired";
                return (
                  <li
                    key={provider.id}
                    class={notSetUp ? "health-source-unconfigured" : undefined}
                  >
                    <div class="health-provider-summary">
                      {provider.logoUrl && (
                        <img
                          src={provider.logoUrl}
                          width="24"
                          height="24"
                          alt=""
                        />
                      )}
                      <strong>{provider.name}</strong>
                      <span>
                        {state.statuses[provider.id] ||
                          (state.loading
                            ? sourceStatus(provider).label
                            : "No qualifying values")}
                      </span>
                    </div>
                    {notSetUp && (
                      <p class="health-source-setup">
                        <a href="?view=accounts">Set up {provider.name}</a>
                      </p>
                    )}
                  </li>
                );
              })}
          </ul>
          <div class="health-source-manage health-source-links">
            <a
              href={`?view=library&root=${encodeURIComponent(props.rootId)}&item=${encodeURIComponent(props.itemId)}`}
            >
              Review metadata
            </a>
            <a href="?view=accounts">Manage metadata sources</a>
          </div>
        </div>
      </div>
    </div>
  );
});

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

interface HealthSelection {
  origin: "Current" | "Proposed";
  valueKey: string;
  revision: number;
  error?: string;
}
type HealthSelections = Record<string, HealthSelection>;

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

// Provider lookups search with these fields, so they are settled before the
// remaining checks. A CBR cannot hold edited metadata either, so converting it
// is just as much a prerequisite.
const PRIORITY_FIELD_ORDER = ["title", "authors", "year"];
const COMIC_ARCHIVE_CODES = new Set([
  "comic-archive-misnamed",
  "comic-archive-proprietary",
]);

function priorityRank(issue: MetadataHealthIssue): number {
  const rank = PRIORITY_FIELD_ORDER.indexOf(issue.field ?? "");
  if (rank !== -1) return rank;
  return COMIC_ARCHIVE_CODES.has(issue.code)
    ? PRIORITY_FIELD_ORDER.length
    : PRIORITY_FIELD_ORDER.length + 1;
}

function isPriorityIssue(issue: MetadataHealthIssue): boolean {
  return priorityRank(issue) <= PRIORITY_FIELD_ORDER.length;
}

// Only issues the reviewer can actually settle hold back the rest, so a
// read-only viewer or a podcast keeps every check visible.
function blocksLaterChecks(grouped: GroupedIssue, canEdit: boolean): boolean {
  if (!canEdit || !isPriorityIssue(grouped.issue)) return false;
  if (COMIC_ARCHIVE_CODES.has(grouped.issue.code)) return true;
  return grouped.entries.every(({ issue, target }) =>
    editableHealthIssue(issue, target, canEdit),
  );
}

function issueAnswered(
  grouped: GroupedIssue,
  selections: HealthSelections,
  hidden: Record<string, boolean>,
): boolean {
  return grouped.entries.every(({ issue, target }) => {
    const key = healthEntryId(target.itemId, issue);
    const selection = selections[key];
    return Boolean(hidden[key] || (selection && !selection.error));
  });
}

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
  return [...grouped.values()].sort(
    (left, right) => priorityRank(left.issue) - priorityRank(right.issue),
  );
}

function distinctValues(entries: HealthIssueEntry[], proposed: boolean) {
  const values = new Map<string, { value: unknown; sources: string[] }>();
  for (const { issue } of entries) {
    const candidates = proposed
      ? (issue.proposedValues ?? [])
      : [{ value: issue.currentValue, sources: issue.currentSources ?? [] }];
    for (const candidate of candidates) {
      if (proposed && !hasHealthValue(candidate.value)) continue;
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

function needsExternalProposal(entries: HealthIssueEntry[]): boolean {
  return entries.every(
    ({ issue }) =>
      !hasHealthValue(issue.currentValue) &&
      !issue.proposedValues?.some((candidate) =>
        hasHealthValue(candidate.value),
      ) &&
      !issue.fileOverride,
  );
}

const HealthDecisionRow = component$<{
  entries: HealthIssueEntry[];
  query: string;
  queryFromFilename?: boolean;
  providers: ProviderDefinition[];
  getSession$: GetHealthLookupSession;
  album?: AlbumTarget;
  showFile: boolean;
  sharedReason?: boolean;
  sharedSources?: boolean;
  multipleFiles?: boolean;
  canEdit: boolean;
  selections: HealthSelections;
  onApply$: ApplyHealthValue;
}>((props) => {
  const { issue, target } = props.entries[0];
  const field = issue.field ?? "";
  const editable =
    props.canEdit && isSettableField(field) && target.mediaKind !== "podcast";
  const autoEligible = editable && needsExternalProposal(props.entries);
  const currents = distinctValues(props.entries, false);
  const proposals = distinctValues(props.entries, true);
  const selectionEntries = props.album
    ? props.entries.filter((entry) => !entry.issue.fileOverride)
    : props.entries;
  const selections = selectionEntries.map(
    (entry) =>
      props.selections[healthEntryId(entry.target.itemId, entry.issue)],
  );
  const selected = (value: unknown, origin: "Current" | "Proposed") =>
    selections.length > 0 &&
    selections.every(
      (selection) =>
        selection &&
        !selection.error &&
        selection.origin === origin &&
        selection.valueKey === healthValueKey(value),
    );
  const failure = selections.find((selection) => selection?.error)?.error;
  const apply$ = $((value: unknown, origin: "Current" | "Proposed") =>
    props.onApply$(value, origin, issue, target, props.album),
  );
  const valueButton = (value: unknown, origin: "Current" | "Proposed") =>
    editable && !isUnset(value) ? (
      <button
        type="button"
        class={{
          "health-value-set": true,
          "is-selected": selected(value, origin),
        }}
        aria-pressed={selected(value, origin)}
        title={`Set this ${origin.toLowerCase()} value for “${field}”`}
        onClick$={() => apply$(value, origin)}
      >
        <span>{renderValue(value)}</span>
        <span class="health-value-action">
          {selected(value, origin)
            ? "✓ Selected"
            : `Use ${origin.toLowerCase()}`}
        </span>
      </button>
    ) : (
      <p class="health-value-text">{renderValue(value)}</p>
    );
  return (
    <tr>
      {props.showFile && (
        <th scope="row">
          <div class="health-file-heading">
            <a
              class="health-review-link health-file-link"
              href={`?view=library&root=${encodeURIComponent(target.rootId)}&item=${encodeURIComponent(target.itemId)}`}
            >
              <span title={target.relativePath}>
                {target.relativePath.split("/").at(-1)}
              </span>
            </a>
          </div>
          {issue.fileOverride && <small>Individual choice</small>}
        </th>
      )}
      <td class="health-value">
        {!editable && <span class="health-value-label">Current</span>}
        {currents.length > 1 && <small>Varies by file</small>}
        {currents.map((candidate, index) => (
          <div class="health-candidate" key={index}>
            {valueButton(candidate.value, "Current")}
            {!props.sharedSources && !!candidate.sources.length && (
              <small>{candidate.sources.join(" · ")}</small>
            )}
          </div>
        ))}
      </td>
      <td class="health-value">
        {(!editable || proposals.length === 0) && (
          <span class="health-value-label">Proposed</span>
        )}
        {proposals.length ? (
          proposals.map((candidate, index) => (
            <div class="health-candidate" key={index}>
              {valueButton(candidate.value, "Proposed")}
              {proposals.length > 1 && (
                <small>
                  {candidate.sources.join(" · ") || "Unknown source"}
                </small>
              )}
            </div>
          ))
        ) : autoEligible ? (
          <HealthAutoProposal
            target={target}
            field={field}
            query={props.query}
            queryFromFilename={props.queryFromFilename}
            providers={props.providers}
            getSession$={props.getSession$}
            selectedValueKey={
              selections.length > 0 &&
              selections.every(
                (selection) =>
                  selection &&
                  !selection.error &&
                  selection.origin === "Proposed" &&
                  selection.valueKey === selections[0]?.valueKey,
              )
                ? selections[0]?.valueKey
                : undefined
            }
            onUse$={async (value) => {
              await apply$(value, "Proposed");
            }}
          />
        ) : (
          <p class="health-value-text health-no-suggestion">No suggestion</p>
        )}
        {failure && (
          <p class="health-choice-error" role="alert">
            {failure}
          </p>
        )}
      </td>
      <td
        class={{ "health-provenance": !props.sharedReason }}
        hidden={props.sharedReason || autoEligible}
      >
        {!props.sharedReason &&
          !autoEligible &&
          [
            ...new Set(
              props.entries.map(({ issue }) =>
                proposedProvenance(issue, props.multipleFiles),
              ),
            ),
          ]
            .filter(Boolean)
            .map((reason) => <p key={reason}>{reason}</p>)}
      </td>
    </tr>
  );
});

// Per-file numbers are settled as one selectable list rather than a repeated
// comparison per file, so a folder of tracks stays scannable and can be
// renumbered in one action.
const NUMBERED_HEALTH_FIELDS = new Set(["volumeNumber"]);
const TRACK_SEQUENCE_CODES = new Set([
  "track-sequence-gap-or-duplicate",
  "track-order-mismatch",
  "missing-track-numbers",
]);
const NUMBER_VALUE = /^\d{1,4}(?:\.\d{1,2})?$/;
const SEQUENCE_START = /^\d{1,4}$/;

function byFileName(entries: HealthIssueEntry[]): HealthIssueEntry[] {
  return [...entries].sort((left, right) =>
    left.target.relativePath.localeCompare(
      right.target.relativePath,
      undefined,
      { numeric: true },
    ),
  );
}

function usableProposals(issue: MetadataHealthIssue) {
  return (issue.proposedValues ?? []).filter((candidate) =>
    hasHealthValue(candidate.value),
  );
}

type NumberAction = "current" | "proposed" | "set" | "sequence";

const HealthNumberTable = component$<{
  entries: HealthIssueEntry[];
  field: string;
  editable: boolean;
  selections: HealthSelections;
  onApply$: ApplyHealthValue;
  onDecision$: QRL<
    (entry: HealthIssueEntry, choice: HealthChoice) => Promise<boolean>
  >;
}>((props) => {
  const picked = useStore<Record<string, boolean>>({});
  const number = useSignal("1");
  const status = useSignal("");
  const selectAll = useSignal<HTMLInputElement>();
  const rows = byFileName(props.entries);
  const ids = rows.map((entry) =>
    healthEntryId(entry.target.itemId, entry.issue),
  );
  const chosen = ids.filter((id) => picked[id]).length;
  useVisibleTask$(({ track }) => {
    const count = track(
      () =>
        props.entries.filter(
          (entry) => picked[healthEntryId(entry.target.itemId, entry.issue)],
        ).length,
    );
    if (selectAll.value)
      selectAll.value.indeterminate = count > 0 && count < props.entries.length;
  });
  const label = metadataFieldLabel(props.field).toLowerCase();
  const typed = number.value.trim();
  const sharedOverride = rows.every((entry) => entry.issue.fileOverride);
  const anyProposal = rows.some((entry) => usableProposals(entry.issue).length);
  const apply$ = $(async (action: NumberAction) => {
    status.value = "";
    const start = Number(number.value.trim());
    const set = number.value.trim();
    const selected = byFileName(props.entries).filter(
      (entry) => picked[healthEntryId(entry.target.itemId, entry.issue)],
    );
    let skipped = 0;
    const saved = await Promise.all(
      selected.map(async (entry, index) => {
        const { issue, target } = entry;
        if (action === "current")
          return isUnset(issue.currentValue)
            ? await props.onDecision$(entry, "current")
            : await props.onApply$(
                issue.currentValue,
                "Current",
                issue,
                target,
              );
        if (action === "proposed") {
          const proposals = usableProposals(issue);
          if (proposals.length !== 1) {
            skipped += 1;
            return true;
          }
          return await props.onApply$(
            proposals[0].value,
            "Proposed",
            issue,
            target,
          );
        }
        const text = action === "sequence" ? String(start + index) : set;
        // A typed number that matches an offered value is recorded as that choice.
        const proposal = usableProposals(issue).find(
          (candidate) => displayValue(candidate.value) === text,
        );
        return proposal
          ? await props.onApply$(proposal.value, "Proposed", issue, target)
          : await props.onApply$(
              displayValue(issue.currentValue) === text
                ? issue.currentValue
                : text,
              "Current",
              issue,
              target,
            );
      }),
    );
    if (saved.some((result) => !result))
      status.value =
        "Some files could not be saved. Their rows remain available to retry.";
    else if (skipped)
      status.value = `${skipped} ${skipped === 1 ? "file has" : "files have"} no single proposal and ${skipped === 1 ? "was" : "were"} left unchanged.`;
  });
  const valueCell = (
    entry: HealthIssueEntry,
    value: unknown,
    origin: "Current" | "Proposed",
    sources: string[],
  ) => {
    const selection =
      props.selections[healthEntryId(entry.target.itemId, entry.issue)];
    const pressed =
      !!selection &&
      !selection.error &&
      selection.origin === origin &&
      selection.valueKey === healthValueKey(value);
    const name = entry.target.relativePath.split("/").at(-1);
    return props.editable && !isUnset(value) ? (
      <button
        type="button"
        class={{ "health-number-value": true, "is-selected": pressed }}
        aria-pressed={pressed}
        aria-label={`Use ${origin.toLowerCase()} ${label} ${displayValue(value)} for ${name}`}
        title={sources.length ? sources.join(" · ") : undefined}
        onClick$={() =>
          props.onApply$(value, origin, entry.issue, entry.target)
        }
      >
        {displayValue(value)}
      </button>
    ) : (
      <span
        class="health-number-text"
        title={sources.length ? sources.join(" · ") : undefined}
      >
        {renderValue(value)}
      </span>
    );
  };
  return (
    <div class="health-number-review">
      {props.editable && (
        <div
          class={{
            "health-number-actions": true,
            "is-active": chosen > 0,
          }}
          role="group"
          aria-label={`Change the ${label} of selected files`}
        >
          <span class="health-number-count" aria-live="polite">
            {chosen} of {rows.length} selected
          </span>
          <button
            type="button"
            disabled={!chosen}
            onClick$={() => apply$("current")}
          >
            Use current
          </button>
          {anyProposal && (
            <button
              type="button"
              disabled={!chosen}
              onClick$={() => apply$("proposed")}
            >
              Use proposed
            </button>
          )}
          <span class="health-number-custom">
            <input
              type="text"
              inputMode="decimal"
              aria-label={`${metadataFieldLabel(props.field)} for selected files`}
              value={number.value}
              maxLength={7}
              onInput$={(_, input) => (number.value = input.value)}
            />
            <button
              type="button"
              disabled={!chosen || !NUMBER_VALUE.test(typed)}
              onClick$={() => apply$("set")}
            >
              Set to {NUMBER_VALUE.test(typed) ? typed : "…"}
            </button>
            <button
              type="button"
              disabled={chosen < 2 || !SEQUENCE_START.test(typed)}
              title="Numbers the selected files in filename order"
              onClick$={() => apply$("sequence")}
            >
              {SEQUENCE_START.test(typed)
                ? `Number ${Number(typed)}, ${Number(typed) + 1}, ${Number(typed) + 2}…`
                : "Number in order"}
            </button>
          </span>
        </div>
      )}
      {status.value && <p role="status">{status.value}</p>}
      <table class="health-number-table">
        <thead>
          <tr>
            {props.editable && (
              <th scope="col" class="health-number-pick">
                <input
                  type="checkbox"
                  ref={selectAll}
                  aria-label="Select all files"
                  checked={chosen === rows.length}
                  onChange$={(_, input) => {
                    for (const id of ids) picked[id] = input.checked;
                  }}
                />
              </th>
            )}
            <th scope="col">File</th>
            <th scope="col">Current</th>
            <th scope="col">Proposed</th>
            <th scope="col" class="health-number-play">
              <span class="sr-only">Play</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((entry, index) => {
            const id = ids[index];
            const { issue, target } = entry;
            const name = target.relativePath.split("/").at(-1);
            const proposals = usableProposals(issue);
            const selection = props.selections[id];
            const failure = selection?.error;
            // A typed value matches neither column, so it is shown beside them.
            const custom =
              selection &&
              !selection.error &&
              ![issue.currentValue, ...proposals.map((p) => p.value)]
                .map(healthValueKey)
                .includes(selection.valueKey)
                ? (JSON.parse(selection.valueKey) as unknown)
                : undefined;
            return (
              <tr key={id} class={{ "is-picked": !!picked[id] }}>
                {props.editable && (
                  <td class="health-number-pick">
                    <input
                      type="checkbox"
                      aria-label={`Select ${name}`}
                      checked={!!picked[id]}
                      onChange$={(_, input) => (picked[id] = input.checked)}
                    />
                  </td>
                )}
                <th scope="row">
                  <a
                    class="health-review-link health-file-link"
                    href={`?view=library&root=${encodeURIComponent(target.rootId)}&item=${encodeURIComponent(target.itemId)}`}
                    title={target.relativePath}
                  >
                    {name}
                  </a>
                  {issue.fileOverride && !sharedOverride && (
                    <small>Individual choice</small>
                  )}
                  {failure && (
                    <p class="health-choice-error" role="alert">
                      {failure}
                    </p>
                  )}
                </th>
                <td>
                  {valueCell(
                    entry,
                    issue.currentValue,
                    "Current",
                    issue.currentSources ?? [],
                  )}
                </td>
                <td>
                  <span class="health-number-options">
                    {proposals.map((candidate, candidateIndex) => (
                      <span key={candidateIndex}>
                        {valueCell(
                          entry,
                          candidate.value,
                          "Proposed",
                          candidate.sources,
                        )}
                      </span>
                    ))}
                    {custom !== undefined ? (
                      <span
                        class="health-number-value is-selected is-custom"
                        title="Set in this review"
                      >
                        <span class="sr-only">Set to </span>
                        {displayValue(custom)}
                      </span>
                    ) : (
                      !proposals.length && (
                        <span class="health-number-text health-no-suggestion">
                          —
                        </span>
                      )
                    )}
                  </span>
                </td>
                <td class="health-number-play">
                  <HealthPlayButton target={target} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
});

const HealthIssueReview = component$<{
  group: HealthGroup;
  getSession$: GetHealthLookupSession;
  grouped: GroupedIssue;
  trackSequence?: boolean;
  providers: ProviderDefinition[];
  canEdit: boolean;
  selectedOnline?: { value: unknown; source: string };
  selections: HealthSelections;
  onApply$: ApplyHealthValue;
  onDecision$: QRL<
    (entry: HealthIssueEntry, choice: HealthChoice) => Promise<boolean>
  >;
  onConverted$: QRL<() => void>;
  onLookup$: QRL<
    (
      issue: MetadataHealthIssue,
      target: MetadataHealthResult,
      primary: ProviderDefinition,
    ) => void
  >;
}>((props) => {
  const individually = useSignal(false);
  const bulkStatus = useSignal("");
  const selectionElement = useSignal<HTMLElement>();
  useVisibleTask$(({ track }) => {
    const selection = track(() => props.selectedOnline);
    if (!selection) return;
    const reveal = () => {
      const element = selectionElement.value;
      revealWhenMounted(() => element);
      element?.focus({ preventScroll: true });
    };
    if (typeof requestAnimationFrame === "function")
      requestAnimationFrame(reveal);
    else reveal();
  });
  const { issue, entries } = props.grouped;
  const mixedIssues =
    new Set(entries.map((entry) => entry.issue.title)).size > 1;
  const issueTitle = mixedIssues
    ? `${metadataFieldLabel(issue.field ?? "metadata")}: review needed`
    : issue.title;
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
  const editable = editableHealthIssue(issue, target, props.canEdit);
  const autoEligible = editable && needsExternalProposal(entries);
  const numbered =
    compares &&
    !album &&
    entries.length > 1 &&
    NUMBERED_HEALTH_FIELDS.has(field);
  const readOnlyTitle =
    !editable && target.mediaKind === "podcast"
      ? "Podcast metadata is managed in its source app."
      : !props.canEdit
        ? "Metadata editing requires editor access."
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
  const sharedReason =
    entries.length > 1 &&
    entries.every(
      (entry) => proposedProvenance(entry.issue) === proposedProvenance(issue),
    );
  const currentSources = (issue.currentSources ?? []).slice().sort();
  const sharedSources =
    entries.length > 1 &&
    currentSources.length > 0 &&
    entries.every(
      (entry) =>
        JSON.stringify((entry.issue.currentSources ?? []).slice().sort()) ===
        JSON.stringify(currentSources),
    );
  // Bulk actions appear only when there is a value to keep or to apply.
  const canKeepAll = entries.some(({ issue: entryIssue }) =>
    hasHealthValue(entryIssue.currentValue),
  );
  const canReplaceAll = entries.some(({ issue: entryIssue }) =>
    entryIssue.proposedValues?.some((candidate) =>
      hasHealthValue(candidate.value),
    ),
  );
  const bulk$ = $(async (choice: "current" | "proposed") => {
    bulkStatus.value = "";
    const eligible = entries.filter(
      ({ issue }) =>
        !issue.fileOverride &&
        (choice !== "proposed" || issue.proposedValues?.length === 1),
    );
    const selected = (entry: HealthIssueEntry) =>
      choice === "current"
        ? entry.issue.currentValue
        : entry.issue.proposedValues![0].value;
    if (
      eligible.length &&
      album &&
      entries.every(
        (entry) => entry.issue.fileOverride || eligible.includes(entry),
      ) &&
      eligible.every(
        (entry) =>
          displayValue(selected(entry)) === displayValue(selected(eligible[0])),
      ) &&
      !isUnset(selected(eligible[0]))
    ) {
      await props.onApply$(
        selected(eligible[0]),
        choice === "current" ? "Current" : "Proposed",
        issue,
        target,
        album,
      );
    } else {
      const saved = await Promise.all(
        eligible.map(async (entry) => {
          return choice === "current" &&
            (!compares || isUnset(entry.issue.currentValue))
            ? await props.onDecision$(entry, choice)
            : await props.onApply$(
                selected(entry),
                choice === "current" ? "Current" : "Proposed",
                entry.issue,
                entry.target,
              );
        }),
      );
      if (saved.some((result) => !result))
        bulkStatus.value =
          "Some files could not be saved. Their issues remain available to retry.";
    }
    if (eligible.length < entries.length)
      bulkStatus.value =
        "Individual choices were retained. Files without one clear proposal still need review.";
  });
  return (
    <section
      class={{
        "health-result-issue": true,
        "is-priority": isPriorityIssue(issue),
      }}
    >
      <header class="health-issue-header">
        <h4>{issueTitle}</h4>
      </header>
      <div class="health-comparison">
        {!compares && <p>{issue.message}</p>}
        {COMIC_ARCHIVE_CODES.has(issue.code) &&
          entries.map((entry) => (
            <div key={entry.target.itemId} class="health-comic-archive">
              {entries.length > 1 && (
                <span>{entry.target.relativePath.split("/").at(-1)}</span>
              )}
              <ComicArchiveAction
                itemId={entry.target.itemId}
                rootId={entry.target.rootId}
                format={
                  entry.issue.code === "comic-archive-misnamed"
                    ? "zip"
                    : undefined
                }
                canEdit={props.canEdit}
                onConverted$={props.onConverted$}
              />
            </div>
          ))}
        {compares && (
          <>
            {numbered ? (
              <HealthNumberTable
                entries={entries}
                field={field}
                editable={editable}
                selections={props.selections}
                onApply$={props.onApply$}
                onDecision$={props.onDecision$}
              />
            ) : (
              <table class="health-issue-table">
                <caption class="sr-only">{issueTitle}</caption>
                <thead class="sr-only">
                  <tr>
                    {!album && entries.length > 1 && <th scope="col">File</th>}
                    <th scope="col">Current</th>
                    <th scope="col">Proposed</th>
                    <th scope="col">Reason</th>
                  </tr>
                </thead>
                <tbody>
                  {album ? (
                    <HealthDecisionRow
                      providers={props.providers}
                      getSession$={props.getSession$}
                      query={groupHeading(props.group).text}
                      queryFromFilename={groupHeading(props.group).fromFilename}
                      key="album"
                      entries={entries}
                      album={album}
                      showFile={false}
                      sharedReason={sharedReason}
                      sharedSources={sharedSources}
                      multipleFiles={count > 1}
                      canEdit={props.canEdit}
                      selections={props.selections}
                      onApply$={props.onApply$}
                    />
                  ) : (
                    entries.map((entry) => (
                      <HealthDecisionRow
                        providers={props.providers}
                        getSession$={props.getSession$}
                        query={groupHeading(props.group).text}
                        queryFromFilename={
                          groupHeading(props.group).fromFilename
                        }
                        key={entry.target.itemId}
                        entries={[entry]}
                        showFile={entries.length > 1}
                        sharedReason={sharedReason}
                        sharedSources={sharedSources}
                        canEdit={props.canEdit}
                        selections={props.selections}
                        onApply$={props.onApply$}
                      />
                    ))
                  )}
                </tbody>
              </table>
            )}
            {((sharedReason && !autoEligible && !!proposedProvenance(issue)) ||
              sharedSources) && (
              <div class="health-provenance">
                {sharedSources && (
                  <p>Current from {quotedList(currentSources)}.</p>
                )}
                {sharedReason &&
                  !autoEligible &&
                  !!proposedProvenance(issue) && (
                    <p>{proposedProvenance(issue, true)}</p>
                  )}
              </div>
            )}
            {!album &&
              ["audiobook", "music"].includes(target.mediaKind) &&
              props.canEdit &&
              !(compares && albumField) && (
                <p class="health-file-scope">
                  This value is saved for the file in Media Manager. Other apps
                  use the album metadata.
                </p>
              )}
            {props.selectedOnline && (
              <div
                class="health-online-selection"
                role="status"
                tabIndex={-1}
                ref={selectionElement}
              >
                <span class="health-issue-context">{issueTitle}</span>
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
      {!numbered &&
        (count > 1 ||
          props.group.results.length > 1 ||
          (compares && albumField) ||
          props.trackSequence) && (
          <div
            class={{
              "health-issue-footer": true,
              "has-bulk": count > 1 || props.trackSequence,
            }}
          >
            <details class="health-file-details">
              <summary>
                {count > 1 || props.group.results.length > 1
                  ? `Affects ${count} ${count === 1 ? "file" : "files"}`
                  : "Files in this folder"}
              </summary>
              {compares && albumField && (
                <div class="health-album-scope">
                  <label>
                    <input
                      type="checkbox"
                      checked={individually.value}
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
              <ul class="health-affected-files">
                {files.map((file) => {
                  const matches = (result: MetadataHealthResult) =>
                    result.relativePath === file ||
                    result.relativePath.endsWith(`/${file}`);
                  const fileTarget = props.group.results.find(matches);
                  const issueTitles = mixedIssues
                    ? [
                        ...new Set(
                          entries
                            .filter((entry) => matches(entry.target))
                            .map((entry) => entry.issue.title),
                        ),
                      ]
                    : [];
                  return (
                    <li key={file}>
                      <div class="health-affected-file">
                        {fileTarget ? (
                          <>
                            <a
                              class="health-review-link"
                              href={`?view=library&root=${encodeURIComponent(fileTarget.rootId)}&item=${encodeURIComponent(fileTarget.itemId)}`}
                              title={fileTarget.relativePath}
                            >
                              {file}
                            </a>
                            <HealthPlayButton target={fileTarget} />
                          </>
                        ) : (
                          <span>{file}</span>
                        )}
                      </div>
                      {issueTitles.length > 0 && (
                        <p>{issueTitles.join("; ")}</p>
                      )}
                    </li>
                  );
                })}
                {count > files.length && (
                  <li aria-label="Additional affected files">…</li>
                )}
              </ul>
            </details>
            {count > 1 && (canKeepAll || canReplaceAll) && (
              <div class="health-issue-actions">
                {canKeepAll && (
                  <button
                    type="button"
                    title={readOnlyTitle}
                    disabled={
                      !editable ||
                      entries.every((entry) => entry.issue.fileOverride)
                    }
                    onClick$={() => bulk$("current")}
                  >
                    Keep all
                  </button>
                )}
                {canReplaceAll && (
                  <button
                    type="button"
                    title={readOnlyTitle}
                    disabled={
                      !editable ||
                      !entries.some(
                        (entry) =>
                          !entry.issue.fileOverride &&
                          entry.issue.proposedValues?.length === 1,
                      )
                    }
                    onClick$={() => bulk$("proposed")}
                  >
                    Replace all
                  </button>
                )}
              </div>
            )}
            {props.trackSequence && (
              <HealthTrackSequence
                target={props.group.results[0]}
                canEdit={props.canEdit}
              />
            )}
          </div>
        )}
      {bulkStatus.value && <p role="status">{bulkStatus.value}</p>}
    </section>
  );
});

const HealthArtwork = component$<{ itemId: string }>((props) => {
  const failed = useSignal(false);
  return (
    <div class="health-result-art" aria-hidden="true" hidden={failed.value}>
      {!failed.value && (
        <img
          src={thumbnailSrc(
            `/api/v1/items/${encodeURIComponent(props.itemId)}/image`,
          )}
          srcset={thumbnailSrcset(
            `/api/v1/items/${encodeURIComponent(props.itemId)}/image`,
          )}
          sizes={thumbnailSizes("360px")}
          alt=""
          loading="lazy"
          onError$={() => (failed.value = true)}
        />
      )}
    </div>
  );
});

const HealthResult = component$<{ group: HealthGroup; canEdit: boolean }>(
  (props) => {
    const issuesElement = useSignal<HTMLElement>();
    const bannerElement = useSignal<HTMLElement>();
    const sticky = useSignal(false);
    const bannerHeight = useSignal(0);
    useVisibleTask$(({ cleanup }) => {
      const issues = issuesElement.value;
      const banner = bannerElement.value;
      if (!issues || !banner || typeof ResizeObserver === "undefined") return;
      const measure = () => {
        // Measure only the queries, excluding the banner. Sticky positioning
        // keeps the same flow height, so it cannot change its own threshold.
        sticky.value =
          issues.getBoundingClientRect().height > window.innerHeight;
        bannerHeight.value = sticky.value
          ? banner.getBoundingClientRect().height
          : 0;
      };
      measure();
      const observer = new ResizeObserver(measure);
      observer.observe(issues);
      observer.observe(banner);
      window.addEventListener("resize", measure);
      cleanup(() => {
        observer.disconnect();
        window.removeEventListener("resize", measure);
      });
    });
    const first = props.group.results[0];
    const heading = groupHeading(props.group);
    const kind = KIND_SYMBOLS[first.mediaKind] ?? {
      icon: "file" as IconName,
      label: first.mediaKind,
    };
    return (
      <article
        class="health-result"
        style={{ "--health-banner-height": `${bannerHeight.value}px` }}
      >
        <header
          ref={bannerElement}
          class={{ "health-result-banner": true, "is-sticky": sticky.value }}
        >
          <HealthArtwork itemId={first.itemId} />
          <div class="health-result-heading">
            <h3 class={{ "health-result-title-file": heading.fromFilename }}>
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
          <div class="health-banner-actions">
            <HealthPlayButton target={first} />
            {props.group.results.length === 1 && (
              <a
                class="health-review-link"
                href={`?view=library&root=${encodeURIComponent(props.group.rootId)}&item=${encodeURIComponent(first.itemId)}`}
              >
                Review metadata
              </a>
            )}
          </div>
        </header>
        <div class="health-result-issues" ref={issuesElement}>
          <Slot name="priority" />
          <Slot />
        </div>
      </article>
    );
  },
);

interface MetadataHealthProps {
  roots: HealthRoot[];
  initialRootId?: string;
  canEdit?: boolean;
  onPlayAudio$?: QRL<(itemId: string) => void>;
}

const MetadataHealthContent = component$<MetadataHealthProps>((props) => {
  const lookupSession = useSignal<NoSerialize<HealthLookupSession>>();
  const getLookupSession$ = $(() => {
    if (!lookupSession.value)
      lookupSession.value = noSerialize(createHealthLookupSession());
    return lookupSession.value!;
  });
  useVisibleTask$(({ cleanup }) => {
    cleanup(() => lookupSession.value?.dispose());
  });
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
    queryFromFilename: boolean;
    selectionKey: string;
  } | null>(null);
  const onlineSelections = useStore<
    Record<string, { value: unknown; source: string }>
  >({});
  const feedback = useStore({ error: "", notice: "" });
  const selections = useStore<HealthSelections>({}, { deep: false });
  const optimisticDecisions = useStore<Record<string, boolean>>({});
  const pruneEntries$ = $((entries: HealthIssueEntry[]) => {
    let remaining = inbox.results;
    for (const entry of entries)
      remaining = withoutHealthEntry(remaining, entry);
    const count = (results: MetadataHealthResult[]) =>
      results.reduce((total, result) => total + result.health.length, 0);
    const removed = count(inbox.results) - count(remaining);
    inbox.results = remaining;
    inbox.issueCount = Math.max(0, inbox.issueCount - removed);
  });
  const saveDecision$ = $(
    async (entry: HealthIssueEntry, choice: HealthChoice, planId?: string) => {
      try {
        await saveHealthDecision(entry, choice, planId);
        return "";
      } catch (cause) {
        return readableError(cause);
      }
    },
  );
  const rememberDecision$ = $(
    (entry: HealthIssueEntry, choice: HealthChoice, planId?: string) => {
      const key = healthEntryId(entry.target.itemId, entry.issue);
      const selection: HealthSelection = {
        origin: choice === "proposed" ? "Proposed" : "Current",
        valueKey: healthValueKey(entry.issue.currentValue),
        revision: (selections[key]?.revision ?? 0) + 1,
      };
      if (choice === "unsure") optimisticDecisions[key] = true;
      else selections[key] = selection;
      enqueueHealthWrite(async () => {
        const failure = await saveDecision$(entry, choice, planId);
        if (failure) {
          delete optimisticDecisions[key];
          if (choice === "unsure") feedback.error = failure;
          else if (selections[key]?.revision === selection.revision)
            selections[key] = {
              ...selection,
              error: `Could not save this choice: ${failure} Select a value to retry.`,
            };
          return;
        }
        if (choice === "unsure") {
          await pruneEntries$([entry]);
          delete optimisticDecisions[key];
          feedback.notice =
            "Hidden until the proposed values or sources change.";
        }
      });
      return true;
    },
  );

  const inspectLibraries = $(async (rootId: string) => {
    const revision = ++requestRevision.value;
    lookupSession.value?.dispose();
    lookupSession.value = undefined;
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

  const rescanAfterConversion$ = $(() => inspectLibraries(inbox.rootId));

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
    (
      value: unknown,
      origin: "Current" | "Proposed",
      issue: MetadataHealthIssue,
      target: MetadataHealthResult,
      album?: AlbumTarget,
    ) => {
      if (!props.canEdit) return false;
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
      const decided: HealthIssueEntry[] = album
        ? inbox.results
            .filter(
              (result) =>
                result.rootId === album.rootId &&
                result.albumGroup === album.path,
            )
            .flatMap((result) =>
              result.health
                .filter(
                  (candidate) =>
                    !candidate.fileOverride &&
                    healthIssueKey(candidate) === healthIssueKey(issue),
                )
                .map((candidate) => ({ issue: candidate, target: result })),
            )
        : [{ issue, target }];
      if (!decided.length) return false;

      // Keep rows mounted and publish the picked value before starting any I/O.
      // Repeated picks are allowed; older saves cannot overwrite newer feedback.
      const picked = decided.map((entry) => {
        const key = healthEntryId(entry.target.itemId, entry.issue);
        const selection: HealthSelection = {
          origin,
          valueKey: healthValueKey(value),
          revision: (selections[key]?.revision ?? 0) + 1,
        };
        selections[key] = selection;
        return { key, selection };
      });

      enqueueHealthWrite(async () => {
        try {
          // A confirmed plan writes the sidecar asynchronously. Previewing the
          // next edit before it lands would fail the source fingerprint check.
          const prior = await settleHealthPlans();
          if (prior.pending)
            throw new Error(
              "A previous metadata change is still queued. Check Activity, then try again.",
            );
          const endpoint = album
            ? `/folders/metadata?rootId=${encodeURIComponent(album.rootId)}&relativePath=${encodeURIComponent(album.path)}`
            : `/items/${encodeURIComponent(target.itemId)}/metadata`;
          const details = await api<Record<string, unknown>>(endpoint);
          const fields = sidecarFieldsFromMetadata(details, field, value);
          if (!String(fields.title ?? "").trim())
            throw new Error(
              "This item needs a title before other metadata can be saved. Set the title first.",
            );
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
          // A preview without actions already matches the file on disk.
          const queued = (preview.actions ?? []).length > 0;
          if (queued) {
            await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
              method: "POST",
              headers: { "if-match": `"${preview.digest}"` },
            });
            unsettledPlans.add(preview.id);
          }
          const decisionFailures: string[] = [];
          for (const entry of decided) {
            const failure = await saveDecision$(
              entry,
              origin === "Current" ? "current" : "proposed",
              queued ? preview.id : undefined,
            );
            if (failure) decisionFailures.push(failure);
          }
          if (queued) {
            const outcome = await settleHealthPlans();
            if (outcome.failure) throw new Error(outcome.failure);
            if (outcome.pending)
              throw new Error(
                "The library is still processing this change. Check Activity before retrying.",
              );
          }
          if (decisionFailures.length)
            throw new Error(
              `The value was saved, but the review choice could not be recorded: ${decisionFailures[0]}`,
            );
        } catch (error) {
          const failure = `Could not save this choice: ${readableError(error)} Select a value to retry.`;
          for (const { key, selection } of picked)
            if (selections[key]?.revision === selection.revision)
              selections[key] = { ...selection, error: failure };
        }
      });
      return true;
    },
  );

  const dialog = providersDialogFor.value;
  const visibleResults = inbox.results
    .map((result) => ({
      ...result,
      health: result.health.filter(
        (issue) => !optimisticDecisions[healthEntryId(result.itemId, issue)],
      ),
    }))
    .filter((result) => result.health.length > 0);
  // Important fixes come first for each item; its remaining checks stay out of
  // the way until those are settled.
  const issueGroups = groupResults(visibleResults).map((group) => {
    const issues = groupIssues(group.results);
    const held = issues.some(
      (grouped) =>
        blocksLaterChecks(grouped, Boolean(props.canEdit)) &&
        !issueAnswered(grouped, selections, optimisticDecisions),
    );
    return {
      group,
      issues,
      held,
      shown: held
        ? issues.filter((grouped) => isPriorityIssue(grouped.issue))
        : issues,
    };
  });
  const heldIssueCount = issueGroups.reduce(
    (total, entry) =>
      entry.held
        ? total +
          entry.issues.reduce(
            (count, grouped) =>
              isPriorityIssue(grouped.issue)
                ? count
                : count + grouped.entries.length,
            0,
          )
        : total,
    0,
  );
  const visibleIssueCount = Math.max(
    0,
    inbox.issueCount -
      hiddenIssueCount(inbox.results, optimisticDecisions) -
      heldIssueCount,
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
            : `${visibleIssueCount} ${visibleIssueCount === 1 ? "issue" : "issues"} across ${inbox.inspectedItems} inspected ${inbox.inspectedItems === 1 ? "item" : "items"}${inbox.errors.length ? " · incomplete" : ""}`}
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
        visibleResults.length === 0 ? (
        <p class="health-empty">
          No metadata issues found in the inspected libraries.
        </p>
      ) : null}

      <div class="health-results">
        {issueGroups.map(({ group, issues, shown }) => (
          <HealthResult
            group={group}
            canEdit={Boolean(props.canEdit)}
            key={group.key}
          >
            {shown.map((grouped, index) => (
              <HealthIssueReview
                q:slot={isPriorityIssue(grouped.issue) ? "priority" : undefined}
                trackSequence={
                  issues.findIndex((candidate) =>
                    candidate.entries.some((entry) =>
                      TRACK_SEQUENCE_CODES.has(entry.issue.code),
                    ),
                  ) === index
                }
                getSession$={getLookupSession$}
                key={`${group.key}-${grouped.key}`}
                group={group}
                grouped={grouped}
                providers={providerCatalog.providers}
                canEdit={Boolean(props.canEdit)}
                selectedOnline={onlineSelections[`${group.key}:${grouped.key}`]}
                selections={selections}
                onApply$={applyValue$}
                onDecision$={rememberDecision$}
                onConverted$={rescanAfterConversion$}
                onLookup$={(issue, target, primary) => {
                  const heading = groupHeading(group);
                  providersDialogFor.value = {
                    issue,
                    mediaKind: target.mediaKind,
                    primary,
                    itemId: target.itemId,
                    rootId: target.rootId,
                    query: heading.text,
                    queryFromFilename: heading.fromFilename,
                    selectionKey: `${group.key}:${grouped.key}`,
                  };
                }}
              />
            ))}
          </HealthResult>
        ))}
      </div>
      {dialog && (
        <ExternalProvidersDialog
          getSession$={getLookupSession$}
          issue={dialog.issue}
          mediaKind={dialog.mediaKind}
          providers={providerCatalog.providers}
          primary={dialog.primary}
          itemId={dialog.itemId}
          rootId={dialog.rootId}
          query={dialog.query}
          queryFromFilename={dialog.queryFromFilename}
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

export const MetadataHealthView = component$<MetadataHealthProps>((props) => (
  <HealthPlayback onPlayAudio$={props.onPlayAudio$}>
    <MetadataHealthContent {...props} />
  </HealthPlayback>
));
