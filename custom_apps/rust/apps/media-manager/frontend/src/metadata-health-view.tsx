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
import {
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

function proposedProvenance(
  issue: MetadataHealthIssue,
  multipleFiles = false,
): string {
  const proposed = issue.proposedValues ?? [];
  if (proposed.length === 0)
    return multipleFiles
      ? "No source provided proposed values for these files."
      : "No source provided a proposed value.";
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
  onSelect$: QRL<(value: unknown, source: string) => void>;
  onClose$: QRL<() => void>;
}>((props) => {
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
      title: state.context.title || initialQuery,
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
    void search();
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
                  <span>Search all sources</span>
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
                  Searching available sources…
                </p>
              ) : null}
              {state.error && (
                <p class="health-lookup-error" role="alert">
                  {state.error}
                </p>
              )}
              {!state.loading && !state.error && matches.length === 0 && (
                <p>No results supply this field with at least a 30% match.</p>
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
  providers: ProviderDefinition[];
  getSession$: GetHealthLookupSession;
  album?: AlbumTarget;
  showFile: boolean;
  sharedReason?: boolean;
  sharedSources?: boolean;
  multipleFiles?: boolean;
  canEdit: boolean;
  applying: boolean;
  onApply$: ApplyHealthValue;
}>((props) => {
  const queuedValue = useSignal("");
  const { issue, target } = props.entries[0];
  const field = issue.field ?? "";
  const editable =
    props.canEdit && isSettableField(field) && target.mediaKind !== "podcast";
  const autoEligible = editable && needsExternalProposal(props.entries);
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
            providers={props.providers}
            getSession$={props.getSession$}
            applying={props.applying}
            onUse$={(value) => apply$(value, "Proposed")}
          />
        ) : (
          <p
            class="health-value-text health-unset"
            aria-label="No proposed value"
          >
            ???
          </p>
        )}
        {queuedValue.value && (
          <p class="health-queued-value" role="status">
            {queuedValue.value}
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
          ].map((reason) => <p key={reason}>{reason}</p>)}
      </td>
    </tr>
  );
});

const HealthIssueReview = component$<{
  group: HealthGroup;
  getSession$: GetHealthLookupSession;
  grouped: GroupedIssue;
  providers: ProviderDefinition[];
  canEdit: boolean;
  applying: boolean;
  selectedOnline?: { value: unknown; source: string };
  onApply$: ApplyHealthValue;
  onDecision$: QRL<
    (entry: HealthIssueEntry, choice: HealthChoice) => Promise<boolean>
  >;
  onLookup$: QRL<
    (
      issue: MetadataHealthIssue,
      target: MetadataHealthResult,
      primary: ProviderDefinition,
    ) => void
  >;
}>((props) => {
  const individually = useSignal(false);
  const bulkWorking = useSignal(false);
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
  const bulk$ = $(async (choice: "current" | "proposed") => {
    if (bulkWorking.value || props.applying) return;
    bulkWorking.value = true;
    bulkStatus.value = "";
    try {
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
            displayValue(selected(entry)) ===
            displayValue(selected(eligible[0])),
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
    } finally {
      bulkWorking.value = false;
    }
  });
  return (
    <section class="health-result-issue">
      <header class="health-issue-header">
        <h4>{issueTitle}</h4>
      </header>
      <div class="health-comparison">
        {!compares && <p>{issue.message}</p>}
        {compares && (
          <>
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
                    key="album"
                    entries={entries}
                    album={album}
                    showFile={false}
                    sharedReason={sharedReason}
                    sharedSources={sharedSources}
                    multipleFiles={count > 1}
                    canEdit={props.canEdit}
                    applying={props.applying}
                    onApply$={props.onApply$}
                  />
                ) : (
                  entries.map((entry) => (
                    <HealthDecisionRow
                      providers={props.providers}
                      getSession$={props.getSession$}
                      query={groupHeading(props.group).text}
                      key={entry.target.itemId}
                      entries={[entry]}
                      showFile={entries.length > 1}
                      sharedReason={sharedReason}
                      sharedSources={sharedSources}
                      canEdit={props.canEdit}
                      applying={props.applying}
                      onApply$={props.onApply$}
                    />
                  ))
                )}
              </tbody>
            </table>
            {((sharedReason && !autoEligible) || sharedSources) && (
              <div class="health-provenance">
                {sharedSources && (
                  <p>Current from {quotedList(currentSources)}.</p>
                )}
                {sharedReason && !autoEligible && (
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
      {(count > 1 ||
        props.group.results.length > 1 ||
        (compares && albumField)) && (
        <div class={{ "health-issue-footer": true, "has-bulk": count > 1 }}>
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
                    {issueTitles.length > 0 && <p>{issueTitles.join("; ")}</p>}
                  </li>
                );
              })}
              {count > files.length && (
                <li aria-label="Additional affected files">…</li>
              )}
            </ul>
          </details>
          {count > 1 && (
            <div class="health-issue-actions">
              <button
                type="button"
                title={readOnlyTitle}
                disabled={
                  !editable ||
                  props.applying ||
                  bulkWorking.value ||
                  entries.every((entry) => entry.issue.fileOverride)
                }
                onClick$={() => bulk$("current")}
              >
                Keep all
              </button>
              <button
                type="button"
                title={readOnlyTitle}
                disabled={
                  !editable ||
                  props.applying ||
                  bulkWorking.value ||
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
            </div>
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
          src={`/api/v1/items/${encodeURIComponent(props.itemId)}/image`}
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
          {props.group.results.some((result) =>
            result.health.some((issue) =>
              [
                "track-sequence-gap-or-duplicate",
                "track-order-mismatch",
                "missing-track-numbers",
              ].includes(issue.code),
            ),
          ) && <HealthTrackSequence target={first} canEdit={props.canEdit} />}
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
    selectionKey: string;
  } | null>(null);
  const onlineSelections = useStore<
    Record<string, { value: unknown; source: string }>
  >({});
  const feedback = useStore({ error: "", notice: "" });
  const applyingValue = useSignal(false);
  const pendingApplies = useSignal(0);
  const pendingTargets = useStore<Record<string, boolean>>({});
  const rememberDecision$ = $(
    async (entry: HealthIssueEntry, choice: HealthChoice, planId?: string) => {
      try {
        await saveHealthDecision(entry, choice, planId);
        const remaining = withoutHealthEntry(inbox.results, entry);
        const removed =
          inbox.results.reduce(
            (count, result) => count + result.health.length,
            0,
          ) -
          remaining.reduce((count, result) => count + result.health.length, 0);
        inbox.results = remaining;
        inbox.issueCount = Math.max(0, inbox.issueCount - removed);
        if (choice === "unsure")
          feedback.notice =
            "Hidden until the proposed values or sources change.";
        else if (choice === "current")
          feedback.notice = "The current values were retained.";
        return true;
      } catch (cause) {
        feedback.error = readableError(cause);
        return false;
      }
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
      const targetKey = album ? `${album.rootId}:${album.path}` : target.itemId;
      if (!props.canEdit || pendingTargets[targetKey]) return false;
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
      pendingTargets[targetKey] = true;
      pendingApplies.value++;
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
        const decided = album
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
        const saved = await Promise.all(
          decided.map((entry) =>
            rememberDecision$(
              entry,
              origin === "Current" ? "current" : "proposed",
              preview.id,
            ),
          ),
        );
        if (saved.some((result) => !result)) return false;
        feedback.notice = `The ${origin.toLowerCase()} “${field}” value was queued for ${album ? "this album" : "this file"}. See Activity to revisit the decision.`;
        return true;
      } catch (error) {
        feedback.error = readableError(error);
        return false;
      } finally {
        delete pendingTargets[targetKey];
        pendingApplies.value--;
        applyingValue.value = pendingApplies.value > 0;
      }
    },
  );

  const dialog = providersDialogFor.value;
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
        {groupResults(inbox.results).map((group) => (
          <HealthResult
            group={group}
            canEdit={Boolean(props.canEdit)}
            key={group.key}
          >
            {groupIssues(group.results).map((grouped) => (
              <HealthIssueReview
                getSession$={getLookupSession$}
                key={`${group.key}-${grouped.key}`}
                group={group}
                grouped={grouped}
                providers={providerCatalog.providers}
                canEdit={Boolean(props.canEdit)}
                applying={applyingValue.value}
                selectedOnline={onlineSelections[`${group.key}:${grouped.key}`]}
                onApply$={applyValue$}
                onDecision$={rememberDecision$}
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
