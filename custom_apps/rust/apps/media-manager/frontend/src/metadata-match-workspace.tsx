import { component$, type QRL } from "@builder.io/qwik";

export const MATCHABLE_METADATA_FIELDS = [
  ["mediaType", "Media type"],
  ["title", "Title"],
  ["year", "Year"],
  ["season", "Season"],
  ["episode", "Episode"],
  ["episodeTitle", "Episode title"],
  ["language", "Language code"],
  ["genres", "Genres"],
  ["authors", "Authors / artists"],
  ["narrators", "Narrators"],
  ["writers", "Writers"],
  ["series", "Series"],
  ["volumeNumber", "Volume"],
  ["publisher", "Publisher / studio"],
  ["premiereDate", "Premiere date"],
  ["runtimeMinutes", "Runtime"],
  ["officialRating", "Official rating"],
  ["communityRating", "Community rating"],
  ["isbn", "ISBN"],
  ["description", "Description"],
] as const;

export type MetadataMatchField = (typeof MATCHABLE_METADATA_FIELDS)[number][0];
export type MetadataMatchSelection = MetadataMatchField | "providerIds";

export type MetadataMatchProvider =
  | {
      kind: "tmdb";
      tmdbId: number;
      seriesTmdbId?: number;
      mediaType: "movie" | "tv" | "season" | "episode";
    }
  | {
      kind: "musicbrainz";
      releaseGroupId: string;
      releaseId?: string;
      matchMethod: "fingerprint" | "search";
    }
  | {
      kind: "open-library";
      workId: string;
      editionId?: string;
    }
  | {
      kind: "google-books";
      volumeId: string;
    };

export interface MetadataMatchCandidate {
  itemKey: string;
  provider: MetadataMatchProvider;
  providerLabel: string;
  title: string;
  provenance: string;
  fields: Partial<Record<MetadataMatchField, string>>;
  providerIds: Record<string, string>;
}

export interface MetadataMatchRow {
  field: MetadataMatchSelection;
  label: string;
  currentValue: string;
  candidateValue: string;
  hasChange: boolean;
}

export interface MetadataMatchPatch {
  fields: Partial<Record<MetadataMatchField, string>>;
  providerIds: Record<string, string>;
}

function usableProviderIdEntries(
  providerIds: Readonly<Record<string, string>>,
): Array<[string, string]> {
  return Object.entries(providerIds).flatMap(([provider, id]) => {
    const normalizedProvider = provider.trim();
    const normalizedId = id.trim();
    const hasInvalidControl = [normalizedProvider, normalizedId].some((value) =>
      [...value].some(
        (character) =>
          character < " " && !["\n", "\r", "\t"].includes(character),
      ),
    );
    return normalizedProvider &&
      normalizedId &&
      normalizedProvider.length <= 64 &&
      normalizedId.length <= 256 &&
      !hasInvalidControl
      ? [[normalizedProvider, normalizedId]]
      : [];
  });
}

export function mergeMetadataProviderIds(
  current: Readonly<Record<string, string>>,
  incoming: Readonly<Record<string, string>>,
): Record<string, string> {
  const merged: Record<string, string> = { ...current };
  for (const [provider, id] of usableProviderIdEntries(incoming)) {
    const comparisonKey = provider.toLowerCase();
    for (const existing of Object.keys(merged)) {
      if (
        existing !== provider &&
        existing.trim().toLowerCase() === comparisonKey
      )
        delete merged[existing];
    }
    merged[provider] = id;
  }
  return merged;
}

export const MetadataMatchWorkspace = component$<{
  candidate: MetadataMatchCandidate;
  rows: MetadataMatchRow[];
  selectedFields: MetadataMatchSelection[];
  canEdit: boolean;
  onToggle$: QRL<(field: MetadataMatchSelection) => void>;
  onApply$: QRL<() => void>;
  onCancel$: QRL<() => void>;
}>((props) => {
  const activeSelection = activeMetadataMatchSelection(
    props.rows,
    props.selectedFields,
  );
  const selected = new Set(activeSelection);
  const changedCount = props.rows.filter((row) => row.hasChange).length;
  return (
    <section
      class="metadata-match-workspace"
      aria-labelledby="metadata-match-title"
    >
      <div class="metadata-match-heading">
        <div>
          <span class="eyebrow">Online match</span>
          <h3 id="metadata-match-title">
            Review {props.candidate.providerLabel} match
          </h3>
          <p>
            <strong>{props.candidate.title}</strong>
            <span>{props.candidate.provenance}</span>
          </p>
        </div>
        <span class="status-badge">Nothing applied yet</span>
      </div>
      <div class="metadata-match-table-scroll">
        <table class="metadata-match-table">
          <thead>
            <tr>
              <th>Field</th>
              <th>Current metadata</th>
              <th>{props.candidate.providerLabel} candidate</th>
            </tr>
          </thead>
          <tbody>
            {props.rows.map((row) => (
              <tr class={{ unchanged: !row.hasChange }} key={row.field}>
                <th>
                  <label>
                    <input
                      type="checkbox"
                      checked={selected.has(row.field)}
                      disabled={!props.canEdit || !row.hasChange}
                      aria-label={`Use ${row.label} from ${props.candidate.providerLabel}`}
                      onClick$={() => props.onToggle$(row.field)}
                    />
                    <span>{row.label}</span>
                  </label>
                </th>
                <td>{row.currentValue}</td>
                <td>{row.candidateValue}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <footer class="metadata-match-actions">
        <p>
          <span class="tabular-number">{activeSelection.length}</span> of{" "}
          <span class="tabular-number">{changedCount}</span> changed fields
          selected. Applying only updates the draft.
        </p>
        <div>
          <button
            class="secondary-button"
            type="button"
            onClick$={props.onCancel$}
          >
            Cancel comparison
          </button>
          <button
            class="primary-button"
            type="button"
            disabled={!props.canEdit || activeSelection.length === 0}
            onClick$={props.onApply$}
          >
            Add selected to draft
          </button>
        </div>
      </footer>
    </section>
  );
});

export function metadataMatchRows(
  candidate: MetadataMatchCandidate,
  currentValues: Readonly<Record<string, string>>,
  currentProviderIds: Readonly<Record<string, string>>,
): MetadataMatchRow[] {
  const rows: MetadataMatchRow[] = MATCHABLE_METADATA_FIELDS.flatMap(
    ([field, label]) => {
      const candidateValue = candidate.fields[field]?.trim();
      if (!candidateValue) return [];
      const currentValue = currentValues[field]?.trim() ?? "";
      return [
        {
          field,
          label,
          currentValue: currentValue || "Not set",
          candidateValue,
          hasChange: currentValue !== candidateValue,
        },
      ];
    },
  );

  const providerIds = usableProviderIdEntries(candidate.providerIds).sort(
    ([left], [right]) => left.localeCompare(right),
  );
  const normalizedCurrentProviderIds = Object.fromEntries(
    usableProviderIdEntries(currentProviderIds).map(([provider, id]) => [
      provider.toLowerCase(),
      id,
    ]),
  );
  if (providerIds.length > 0) {
    const currentValue = providerIds
      .map(
        ([provider]) =>
          `${provider}: ${normalizedCurrentProviderIds[provider.toLowerCase()] || "Not set"}`,
      )
      .join("; ");
    const candidateValue = providerIds
      .map(([provider, id]) => `${provider}: ${id}`)
      .join("; ");
    rows.push({
      field: "providerIds",
      label: "Provider IDs",
      currentValue,
      candidateValue,
      hasChange: currentValue !== candidateValue,
    });
  }
  return rows;
}

export function defaultMetadataMatchSelection(
  rows: readonly MetadataMatchRow[],
): MetadataMatchSelection[] {
  return rows.filter((row) => row.hasChange).map((row) => row.field);
}

export function activeMetadataMatchSelection(
  rows: readonly MetadataMatchRow[],
  selection: readonly MetadataMatchSelection[],
): MetadataMatchSelection[] {
  const changed = new Set(
    rows.filter((row) => row.hasChange).map((row) => row.field),
  );
  return selection.filter((field) => changed.has(field));
}

export function selectedMetadataMatchPatch(
  candidate: MetadataMatchCandidate,
  selection: readonly MetadataMatchSelection[],
): MetadataMatchPatch {
  const selected = new Set(selection);
  const fields = Object.fromEntries(
    MATCHABLE_METADATA_FIELDS.flatMap(([field]) => {
      const value = candidate.fields[field]?.trim();
      return selected.has(field) && value ? [[field, value]] : [];
    }),
  ) as Partial<Record<MetadataMatchField, string>>;
  const providerIds = selected.has("providerIds")
    ? Object.fromEntries(usableProviderIdEntries(candidate.providerIds))
    : {};
  return { fields, providerIds };
}
