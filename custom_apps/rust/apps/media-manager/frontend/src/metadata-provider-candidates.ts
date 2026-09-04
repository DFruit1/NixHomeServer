import type {
  MetadataMatchCandidate,
  MetadataMatchField,
} from "./metadata-match-workspace";
import type { OpenLibraryCandidate } from "./open-library-panel";

export type MusicLookupMode = "auto" | "fingerprint" | "search";

export interface MusicCandidate {
  releaseGroupId: string;
  releaseId?: string;
  artist: string;
  title: string;
  releaseType?: string;
  year?: number;
  releaseDate?: string;
  releaseStatus?: string;
  country?: string;
  barcode?: string;
  catalogNumber?: string;
  packaging?: string;
  disambiguation?: string;
  genres: string[];
  label?: string;
  trackCount?: number;
  matchMethod: "fingerprint" | "search";
}

export interface TmdbCandidate {
  mediaType: "movie" | "tv";
  tmdbId: number;
  title: string;
  year?: number;
  overview?: string;
  voteAverage?: number;
  voteCount?: number;
  posterPath?: string;
}

export interface TmdbDetails {
  mediaType: "movie" | "tv" | "season" | "episode";
  tmdbId: number;
  seriesTmdbId?: number;
  seriesTitle?: string;
  title: string;
  episodeTitle?: string;
  year?: number;
  overview?: string;
  voteAverage?: number;
  voteCount?: number;
  posterPath?: string;
  stillPath?: string;
  runtimeMinutes?: number;
  season?: number;
  episode?: number;
  genres?: string[];
  releaseDate?: string;
  firstAirDate?: string;
  airDate?: string;
  crew?: Array<{ name: string; job: string; department?: string }>;
  externalIds?: { imdbId?: string; wikidataId?: string };
}

export interface GoogleBooksCandidate {
  volumeId: string;
  title: string;
  subtitle?: string;
  authors: string[];
  publisher?: string;
  publishedDate?: string;
  year?: number;
  description?: string;
  isbn?: string;
  categories: string[];
  language?: string;
  pageCount?: number;
  averageRating?: number;
  ratingsCount?: number;
  coverAvailable: boolean;
}

const LIST_FIELDS = new Set(["authors", "narrators", "genres", "writers"]);
const NUMERIC_FIELDS = new Set([
  "year",
  "season",
  "episode",
  "runtimeMinutes",
  "communityRating",
]);

export function metadataSourceEditorValue(
  field: MetadataMatchField,
  value: unknown,
): string | undefined {
  let normalized: string;
  if (LIST_FIELDS.has(field)) {
    const maximumEntries = ["authors", "narrators"].includes(field) ? 32 : 64;
    if (
      Array.isArray(value) &&
      value.some((entry) => typeof entry !== "string")
    )
      return undefined;
    if (!Array.isArray(value) && typeof value !== "string") return undefined;
    const entries = (Array.isArray(value) ? value : String(value).split(","))
      .map((entry) => entry.trim())
      .filter(Boolean);
    if (
      entries.length > maximumEntries ||
      entries.some(
        (entry) =>
          entry.length > 500 ||
          [...entry].some(
            (character) =>
              character < " " && !["\n", "\r", "\t"].includes(character),
          ),
      )
    )
      return undefined;
    normalized = entries.join(", ");
  } else if (typeof value === "string") {
    normalized = value.trim();
  } else if (typeof value === "number" && NUMERIC_FIELDS.has(field)) {
    normalized = Number.isFinite(value) ? String(value) : "";
  } else {
    return undefined;
  }
  if (NUMERIC_FIELDS.has(field)) {
    const numeric = Number(normalized);
    const valid =
      Number.isFinite(numeric) &&
      (field === "communityRating"
        ? numeric >= 0 && numeric <= 10
        : Number.isInteger(numeric) &&
          (field === "year"
            ? numeric >= 1 && numeric <= 2100
            : field === "season"
              ? numeric >= 0 && numeric <= 10_000
              : numeric >= 1 && numeric <= 100_000));
    if (!valid) return undefined;
    normalized = String(numeric);
  }
  if (field === "language") {
    normalized = normalized.toLowerCase();
    if (!/^[a-z]{2,3}(?:-[a-z0-9]{2,8})?$/.test(normalized)) return undefined;
  }
  if (field === "premiereDate") {
    const date = normalized.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!date) return undefined;
    const parsed = new Date(`${normalized}T00:00:00Z`);
    if (
      Number.isNaN(parsed.valueOf()) ||
      parsed.toISOString().slice(0, 10) !== normalized
    )
      return undefined;
  }
  const maximum =
    field === "description"
      ? 20_000
      : LIST_FIELDS.has(field)
        ? 32_000
        : field === "volumeNumber"
          ? 32
          : ["isbn", "officialRating"].includes(field)
            ? 64
            : field === "language"
              ? 15
              : field === "premiereDate"
                ? 10
                : 500;
  if (
    !normalized ||
    normalized.length > maximum ||
    [...normalized].some(
      (character) => character < " " && !["\n", "\r", "\t"].includes(character),
    )
  )
    return undefined;
  return normalized;
}

function fields(
  entries: Array<[MetadataMatchField, unknown]>,
): Partial<Record<MetadataMatchField, string>> {
  return Object.fromEntries(
    entries.flatMap(([field, value]) => {
      const normalized = metadataSourceEditorValue(field, value);
      return normalized ? [[field, normalized]] : [];
    }),
  );
}

const MBID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function musicMetadataMatchCandidate(
  itemKey: string,
  candidate: MusicCandidate,
): MetadataMatchCandidate | undefined {
  if (
    !MBID.test(candidate.releaseGroupId) ||
    !["fingerprint", "search"].includes(candidate.matchMethod)
  )
    return undefined;
  if (candidate.releaseId && !MBID.test(candidate.releaseId)) return undefined;
  const matchedFields = fields([
    ["title", candidate.title],
    ["authors", candidate.artist],
    ["year", candidate.year],
    ["genres", candidate.genres],
    ["publisher", candidate.label],
    ["premiereDate", candidate.releaseDate?.slice(0, 10)],
  ]);
  if (!matchedFields.title) return undefined;
  const providerIds: Record<string, string> = {
    "musicbrainz-release-group": candidate.releaseGroupId,
    musicbrainz: candidate.releaseId ?? candidate.releaseGroupId,
  };
  if (candidate.releaseId)
    providerIds["musicbrainz-release"] = candidate.releaseId;
  if (candidate.barcode) providerIds.barcode = candidate.barcode;
  return {
    itemKey,
    provider: {
      kind: "musicbrainz",
      releaseGroupId: candidate.releaseGroupId,
      releaseId: candidate.releaseId,
      matchMethod: candidate.matchMethod,
    },
    providerLabel: "MusicBrainz",
    title: [matchedFields.authors, matchedFields.title]
      .filter(Boolean)
      .join(" — "),
    provenance: candidate.releaseId
      ? `Exact release ${candidate.releaseId}`
      : `Release group ${candidate.releaseGroupId}`,
    fields: matchedFields,
    providerIds,
  };
}

export function tmdbMetadataMatchCandidate(
  itemKey: string,
  details: TmdbDetails,
): MetadataMatchCandidate | undefined {
  if (!Number.isInteger(details.tmdbId) || details.tmdbId < 1) return undefined;
  const writers = Array.isArray(details.crew)
    ? details.crew
        .filter((member) =>
          ["Writer", "Screenplay", "Teleplay", "Story"].includes(member.job),
        )
        .map((member) => member.name)
        .filter((name, index, names) => names.indexOf(name) === index)
    : [];
  const date = details.releaseDate ?? details.firstAirDate ?? details.airDate;
  const matchedFields = fields([
    ["mediaType", details.mediaType === "tv" ? "series" : details.mediaType],
    ["title", details.title],
    ["episodeTitle", details.episodeTitle],
    ["series", details.seriesTitle],
    ["year", details.year],
    ["season", details.season],
    ["episode", details.episode],
    ["description", details.overview],
    ["runtimeMinutes", details.runtimeMinutes],
    ["communityRating", details.voteAverage],
    ["genres", details.genres],
    ["writers", writers],
    ["premiereDate", date?.slice(0, 10)],
  ]);
  if (!matchedFields.title) return undefined;
  const providerIds: Record<string, string> = { tmdb: String(details.tmdbId) };
  if (details.seriesTmdbId)
    providerIds["tmdb-series"] = String(details.seriesTmdbId);
  if (
    typeof details.externalIds?.imdbId === "string" &&
    /^tt\d{5,12}$/i.test(details.externalIds.imdbId)
  )
    providerIds.imdb = details.externalIds.imdbId;
  if (
    typeof details.externalIds?.wikidataId === "string" &&
    /^Q\d{1,16}$/i.test(details.externalIds.wikidataId)
  )
    providerIds.wikidata = details.externalIds.wikidataId;
  return {
    itemKey,
    provider: {
      kind: "tmdb",
      tmdbId: details.tmdbId,
      seriesTmdbId: details.seriesTmdbId,
      mediaType: details.mediaType,
    },
    providerLabel: "TMDB",
    title: `${matchedFields.title}${matchedFields.year ? ` (${matchedFields.year})` : ""}`,
    provenance: `${details.mediaType[0].toUpperCase()}${details.mediaType.slice(1)} details`,
    fields: matchedFields,
    providerIds,
  };
}

function openLibraryLanguage(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const normalized = value.trim().toLowerCase();
  const twoLetterCode: Record<string, string> = {
    deu: "de",
    eng: "en",
    fra: "fr",
    ita: "it",
    jpn: "ja",
    kor: "ko",
    nld: "nl",
    por: "pt",
    rus: "ru",
    spa: "es",
    zho: "zh",
  };
  return twoLetterCode[normalized] ?? normalized;
}

export function openLibraryMetadataMatchCandidate(
  itemKey: string,
  candidate: OpenLibraryCandidate,
): MetadataMatchCandidate | undefined {
  if (
    !/^OL\d{1,16}W$/.test(candidate.workId) ||
    (candidate.editionId != null && !/^OL\d{1,16}M$/.test(candidate.editionId))
  )
    return undefined;
  const matchedFields = fields([
    ["title", candidate.editionTitle ?? candidate.title],
    ["year", candidate.publishYear ?? candidate.firstPublishYear],
    ["authors", candidate.authors],
    ["publisher", candidate.publishers],
    ["isbn", candidate.isbn13 ?? candidate.isbn10],
    ["language", openLibraryLanguage(candidate.languages[0])],
    ["genres", candidate.subjects],
  ]);
  if (!matchedFields.title) return undefined;
  const providerIds: Record<string, string> = {
    openlibrary: candidate.editionId ?? candidate.workId,
  };
  if (candidate.editionId) providerIds["openlibrary-work"] = candidate.workId;
  return {
    itemKey,
    provider: {
      kind: "open-library",
      workId: candidate.workId,
      editionId: candidate.editionId,
    },
    providerLabel: "Open Library",
    title: `${matchedFields.title}${matchedFields.year ? ` (${matchedFields.year})` : ""}`,
    provenance: candidate.editionId
      ? `Edition ${candidate.editionId}`
      : `Work ${candidate.workId}`,
    fields: matchedFields,
    providerIds,
  };
}

export function googleBooksMetadataMatchCandidate(
  itemKey: string,
  candidate: GoogleBooksCandidate,
): MetadataMatchCandidate | undefined {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(candidate.volumeId)) return undefined;
  const matchedFields = fields([
    ["title", candidate.title],
    ["authors", candidate.authors],
    ["publisher", candidate.publisher],
    ["year", candidate.year],
    ["isbn", candidate.isbn],
    ["language", candidate.language],
    ["genres", candidate.categories],
    ["description", candidate.description],
  ]);
  if (!matchedFields.title) return undefined;
  return {
    itemKey,
    provider: { kind: "google-books", volumeId: candidate.volumeId },
    providerLabel: "Google Books",
    title: `${matchedFields.title}${matchedFields.year ? ` (${matchedFields.year})` : ""}`,
    provenance: `Volume ${candidate.volumeId}`,
    fields: matchedFields,
    providerIds: { "google-books": candidate.volumeId },
  };
}
