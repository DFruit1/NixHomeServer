import { MATCHABLE_METADATA_FIELDS as EDITABLE_METADATA_FIELDS } from "./metadata-match-workspace";
import type { MetadataMatchField } from "./metadata-match-workspace";
import { metadataSourceEditorValue } from "./metadata-provider-candidates";
import type {
  CatalogItem,
  DashboardState,
  MetadataObservation,
  NamingProfile,
} from "./root-types";

type EditableMetadataField = MetadataMatchField;

export type EditorTab = "metadata" | "rename" | "subtitles";

export type MetadataSection = "basics" | "people" | "advanced";

export const METADATA_SECTIONS: Array<{ id: MetadataSection; label: string }> =
  [
    { id: "basics", label: "Basics" },
    { id: "people", label: "People" },
    { id: "advanced", label: "Advanced" },
  ];

export const INSPECTED_METADATA_FIELDS = [
  "title",
  "subtitle",
  "year",
  "series",
  "volumeNumber",
  "authors",
  "narrators",
  "publisher",
  "isbn",
  "language",
  "genres",
  "tags",
  "publishedDate",
  "explicit",
  "ageRating",
  "publicationStatus",
  "description",
] as const;

export const REVIEWED_METADATA_FIELDS = [
  ...EDITABLE_METADATA_FIELDS,
  ["providerIds", "Provider IDs"],
] as const;

export const SOURCE_SELECTABLE_METADATA_FIELDS =
  EDITABLE_METADATA_FIELDS.filter(([field]) => field !== "mediaType");

export interface MetadataFieldChange {
  field: string;
  label: string;
  before: string;
  after: string;
}

export interface MetadataSourceChoice {
  field: EditableMetadataField;
  label: string;
  options: Array<{ source: string; label: string; value: string }>;
}

export function metadataSourceChoices(
  observations: Array<Pick<MetadataObservation, "source" | "label" | "fields">>,
  currentValues: Readonly<Record<string, string>>,
): MetadataSourceChoice[] {
  return SOURCE_SELECTABLE_METADATA_FIELDS.flatMap(([field, label]) => {
    const options = observations.flatMap((observation) => {
      const value = metadataSourceEditorValue(field, observation.fields[field]);
      return value
        ? [
            {
              source: observation.source,
              label: observation.label,
              value,
            },
          ]
        : [];
    });
    if (!options.some((option) => option.value !== currentValues[field]))
      return [];
    return [{ field, label, options }];
  });
}

export function metadataFieldChanges(
  before: Readonly<Record<string, string>>,
  after: Readonly<Record<string, string>>,
): MetadataFieldChange[] {
  return REVIEWED_METADATA_FIELDS.flatMap(([field, label]) => {
    const previous = before[field] ?? "";
    const next = after[field] ?? "";
    if (previous === next) return [];
    return [
      {
        field,
        label,
        before: previous || "Not set",
        after: next || "Not set",
      },
    ];
  });
}

export function allowMetadataDraftDiscard(isDirty: boolean): boolean {
  if (!isDirty) return true;
  if (typeof globalThis.confirm !== "function") return false;
  return globalThis.confirm(
    "Discard the unsaved metadata draft? This cannot be undone.",
  );
}

export function metadataFieldLabel(field: string): string {
  return field
    .replace(/([A-Z])/g, " $1")
    .replace(/^./, (value) => value.toUpperCase());
}

export function metadataFieldValue(value: unknown): string {
  if (Array.isArray(value)) return value.map(String).join(", ");
  if (value && typeof value === "object") return JSON.stringify(value);
  if (value == null || value === "") return "—";
  return String(value);
}

export function metadataDuration(value: unknown): string {
  const seconds = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = Math.floor(seconds % 60);
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

export function mediaTypeForItem(item?: CatalogItem): string {
  switch (item?.mediaKind) {
    case "music":
      return "music";
    case "audiobook":
      return "audiobook";
    case "book":
      return "book";
    default:
      return "movie";
  }
}

export function mediaTypeForFolder(
  category: string | undefined,
  path: string,
): string {
  switch (category) {
    case "music":
      return "music";
    case "audiobooks":
      return "audiobook";
    case "books":
      return "book";
    case "videos":
      if (path.startsWith("_Shows/")) {
        return /(?:^|\/)Season\s+\d+$/i.test(path) ? "season" : "series";
      }
      return "movie";
    default:
      return "movie";
  }
}

export function profileForCategory(category?: string): NamingProfile {
  switch (category) {
    case "videos":
      return "movie";
    case "music":
      return "music";
    case "audiobooks":
      return "audiobook";
    case "books":
      return "book";
    default:
      return "filename";
  }
}

export function profilesForCategory(
  category?: string,
): Array<{ id: NamingProfile; label: string }> {
  switch (category) {
    case "videos":
      return [
        { id: "movie", label: "Movie" },
        { id: "tv", label: "TV episode" },
      ];
    case "music":
      return [{ id: "music", label: "Music track" }];
    case "audiobooks":
      return [{ id: "audiobook", label: "Audiobook" }];
    case "books":
      return [{ id: "book", label: "Book" }];
    default:
      return [{ id: "filename", label: "File" }];
  }
}

export function renameReady(state: DashboardState): boolean {
  if (!state.editTitle.trim()) return false;
  if (
    state.editYear &&
    (Number(state.editYear) < 1 || Number(state.editYear) > 2100)
  )
    return false;
  switch (state.editProfile) {
    case "tv":
      return (
        state.editSeason !== "" &&
        state.editEpisode !== "" &&
        Number(state.editEpisode) > 0
      );
    case "music":
      return Boolean(
        state.editCreator.trim() &&
          state.editCollection.trim() &&
          Number(state.editTrack) > 0,
      );
    case "audiobook":
    case "book":
      return Boolean(state.editCreator.trim());
    default:
      return true;
  }
}

export function numericValue(value: string, length: number): string {
  return value.replace(/\D/g, "").slice(0, length);
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

export function commaSeparated(value: string): string[] {
  return value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}
