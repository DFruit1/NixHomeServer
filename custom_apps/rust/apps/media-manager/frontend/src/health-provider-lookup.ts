import type { ProviderDefinition } from "./api-contract.generated";
import { api } from "./api";

const SEARCH_PROVIDERS = new Set([
  "tmdb",
  "musicbrainz",
  "acoustid",
  "open-library",
  "google-books",
  "omdb",
  "tvdb",
  "wikidata",
  "discogs",
  "theaudiodb",
  "comic-vine",
  "isbndb",
  "podcast-index",
  "subdl",
  "opensubtitles",
]);
export function healthLookupAvailability(
  provider: ProviderDefinition,
  context: Record<string, unknown>,
): string {
  if (provider.implementationStatus !== "active") return "Coming soon";
  if (!["configured", "notRequired"].includes(provider.account.state))
    return "Not set up";
  if (provider.id === "audnexus")
    return (context.providerIds as Record<string, unknown> | undefined)?.asin
      ? ""
      : "ASIN required";
  if (!SEARCH_PROVIDERS.has(provider.id))
    return "Artwork source · use metadata editor";
  return "";
}
export async function lookupHealthProvider(
  provider: string,
  query: string,
  itemId: string,
  context: Record<string, unknown>,
): Promise<Record<string, unknown>[]> {
  const music = provider === "musicbrainz" || provider === "acoustid";
  const exactIsbn = isbn(context.isbn);
  const bookQuery =
    exactIsbn && ["open-library", "google-books", "isbndb"].includes(provider)
      ? provider === "isbndb"
        ? exactIsbn
        : `isbn:${exactIsbn}`
      : query;
  const body = music
    ? {
        mode: provider === "acoustid" ? "fingerprint" : "search",
        title: query,
        ...(context.authors
          ? {
              artist: Array.isArray(context.authors)
                ? context.authors.join(", ")
                : String(context.authors),
            }
          : {}),
      }
    : provider === "tmdb"
      ? { query, mediaType: "auto" }
      : provider === "opensubtitles"
        ? { query, languages: String(context.language || "en") }
        : provider === "audnexus"
          ? { id: (context.providerIds as Record<string, unknown>).asin }
          : { query: bookQuery };
  const response = await api<{
    results?: Record<string, unknown>[];
    candidates?: Record<string, unknown>[];
  }>(
    music
      ? `/items/${encodeURIComponent(itemId)}/metadata/lookup`
      : `/provider-lookups/${provider}/search`,
    { method: "POST", body: JSON.stringify(body) },
  );
  return response.results ?? response.candidates ?? [];
}

export const MIN_HEALTH_MATCH = 30;
export const AUTO_HEALTH_MATCH = 75;

export interface HealthMatch {
  title: string;
  provider: ProviderDefinition;
  values: Record<string, unknown>;
  providerIds: Record<string, unknown>;
  scope?: "work" | "edition";
  matchMethod?: string;
  detailError?: string;
}
export interface MatchEvidence {
  score: number;
  reasons: string[];
}
export interface RankedHealthMatch extends HealthMatch {
  confidence: MatchEvidence;
}

function normalized(value: unknown): string {
  return (Array.isArray(value) ? value.join(" ") : String(value ?? ""))
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}
export function hasHealthValue(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(hasHealthValue);
  return (
    value !== null &&
    value !== undefined &&
    !["", "n a", "unknown", "not set", "null"].includes(normalized(value))
  );
}
function similarity(left: unknown, right: unknown): number {
  const a = normalized(left),
    b = normalized(right);
  if (!a || !b) return 0;
  if (a === b) return 1;
  const x = new Set(a.split(" ")),
    y = new Set(b.split(" "));
  return (
    [...x].filter((word) => y.has(word)).length / new Set([...x, ...y]).size
  );
}
const LANGUAGES: Record<string, string> = {
  eng: "en",
  english: "en",
  fra: "fr",
  fre: "fr",
  french: "fr",
  deu: "de",
  ger: "de",
  german: "de",
  spa: "es",
  spanish: "es",
  ita: "it",
  italian: "it",
  por: "pt",
  portuguese: "pt",
  nld: "nl",
  dut: "nl",
  jpn: "ja",
  japanese: "ja",
  zho: "zh",
  chi: "zh",
  chinese: "zh",
  rus: "ru",
  russian: "ru",
  ara: "ar",
  kor: "ko",
};
function language(value: unknown): string {
  const text = String(value ?? "")
    .toLowerCase()
    .split(/[-_]/)[0];
  return LANGUAGES[text] ?? text;
}
/** ISBN-10 and ISBN-13 identify editions, not the umbrella work. Validate checksums. */
function isbn(value: unknown): string {
  let text = String(value ?? "")
    .replace(/[^\dX]/gi, "")
    .toUpperCase();
  if (/^\d{9}[\dX]$/.test(text)) {
    const sum = [...text].reduce(
      (s, c, i) => s + (c === "X" ? 10 : Number(c)) * (10 - i),
      0,
    );
    if (sum % 11) return "";
    text = "978" + text.slice(0, 9);
    const sum13 = [...text].reduce(
      (s, c, i) => s + Number(c) * (i % 2 ? 3 : 1),
      0,
    );
    return text + ((10 - (sum13 % 10)) % 10);
  }
  if (!/^\d{13}$/.test(text)) return "";
  return [...text].reduce((s, c, i) => s + Number(c) * (i % 2 ? 3 : 1), 0) % 10
    ? ""
    : text;
}
const ID_KEYS = new Set([
  "asin",
  "imdb",
  "tmdb",
  "tmdb-series",
  "tvdb",
  "wikidata",
  "google-books",
  "open-library-work",
  "open-library-edition",
  "musicbrainz-release",
  "musicbrainz-release-group",
  "discogs",
  "barcode",
]);
function sourceFamily(id: string) {
  return id === "acoustid" ? "musicbrainz" : id;
}
function sameField(field: string, a: unknown, b: unknown): boolean {
  if (field === "language") return language(a) === language(b);
  if (field === "isbn") return !!isbn(a) && isbn(a) === isbn(b);
  if (Array.isArray(a) || Array.isArray(b)) {
    const parts = (v: unknown) =>
      (Array.isArray(v) ? v : String(v).split(","))
        .map(normalized)
        .sort()
        .join("|");
    return parts(a) === parts(b);
  }
  return normalized(a) === normalized(b);
}

/** Identity evidence is scored independently from field availability and search ranking.
 * Search relevance/popularity is not a probability of a correct metadata value.
 * https://openlibrary.org/dev/docs/api/books (work versus edition)
 * https://musicbrainz.org/doc/MusicBrainz_API/Search (search score)
 */
export function matchConfidence(
  candidate: HealthMatch,
  context: Record<string, unknown>,
  field: string,
  candidates: HealthMatch[],
): MatchEvidence {
  let earned = 0,
    possible = 0,
    supporting = 0,
    identityMatches = 0,
    identityConflicts = 0;
  const reasons: string[] = [];
  let cap = 95;
  const compare = (key: string, weight: number) => {
    // Do not use the value we are trying to discover as evidence for itself.
    if ((key === field && field !== "title") || !hasHealthValue(context[key]))
      return;
    possible += weight;
    const present = hasHealthValue(candidate.values[key]);
    const match = !present
      ? 0
      : key === "language"
        ? Number(language(candidate.values[key]) === language(context[key]))
        : key === "isbn"
          ? Number(
              !!isbn(context[key]) &&
                isbn(candidate.values[key]) === isbn(context[key]),
            )
          : key === "mediaType"
            ? Number(
                String(candidate.values[key]).replace(/^series$/, "tv") ===
                  String(context[key]).replace(/^series$/, "tv"),
              )
            : similarity(candidate.values[key], context[key]);
    earned += weight * match;
    if (
      match >= 0.85 &&
      [
        "authors",
        "year",
        "series",
        "volumeNumber",
        "season",
        "episode",
      ].includes(key)
    )
      supporting++;
    reasons.push(
      `${key}: ${!present ? "unavailable" : match === 1 ? "matches" : match > 0 ? "partial match" : "differs"}`,
    );
    if (
      key === "isbn" &&
      present &&
      isbn(context[key]) &&
      isbn(candidate.values[key])
    ) {
      if (match === 1) identityMatches++;
      else identityConflicts++;
    }
    if (present && !match) {
      if (["mediaType", "volumeNumber", "season", "episode"].includes(key))
        cap = Math.min(cap, 29);
      else if (key === "authors") cap = Math.min(cap, 45);
      else if (key === "year") cap = Math.min(cap, 65);
    }
  };
  compare("title", 50);
  compare("mediaType", 10);
  compare("authors", 25);
  compare("year", 10);
  compare("language", 5);
  compare("publisher", 8);
  compare("series", 12);
  compare("volumeNumber", 20);
  compare("season", 20);
  compare("episode", 20);
  if (isbn(context.isbn)) compare("isbn", 50);
  const ids = context.providerIds as Record<string, unknown> | undefined;
  for (const [key, value] of Object.entries(candidate.providerIds)) {
    if (
      !ID_KEYS.has(key) ||
      !hasHealthValue(ids?.[key]) ||
      !hasHealthValue(value)
    )
      continue;
    const same = normalized(ids![key]) === normalized(value);
    if (same) identityMatches++;
    else identityConflicts++;
    reasons.push(`${key} identifier ${same ? "matches" : "differs"}`);
  }
  const titleMatch = similarity(candidate.values.title, context.title);
  if (identityMatches) {
    possible += 60;
    earned += 60;
  } else if (titleMatch < 0.35) cap = Math.min(cap, 29);
  if (identityConflicts) {
    cap = Math.min(cap, 19);
    reasons.push("Conflicting edition or item identifier; do not auto-propose");
  }
  if (!identityMatches && !supporting) {
    cap = Math.min(cap, 60);
    reasons.push("Title alone cannot identify the edition or release");
  }
  // A fingerprint locates a recording/release group, not a particular edition.
  if (candidate.matchMethod === "fingerprint")
    reasons.push(
      "Audio fingerprint supports the recording; edition may differ",
    );
  if (
    candidate.scope === "work" &&
    [
      "year",
      "language",
      "publisher",
      "isbn",
      "narrators",
      "volumeNumber",
    ].includes(field)
  ) {
    cap = Math.min(cap, 60);
    reasons.push(
      "Work-level search data does not verify this edition-specific field",
    );
  }
  if (candidate.detailError) {
    cap = Math.min(cap, 74);
    reasons.push(candidate.detailError);
  }
  const agreement = new Set(
    candidates
      .filter(
        (other) =>
          sourceFamily(other.provider.id) !==
            sourceFamily(candidate.provider.id) &&
          similarity(other.values.title, candidate.values.title) >= 0.8 &&
          (!hasHealthValue(candidate.values.authors) ||
            !hasHealthValue(other.values.authors) ||
            similarity(other.values.authors, candidate.values.authors) >=
              0.8) &&
          hasHealthValue(candidate.values[field]) &&
          sameField(field, other.values[field], candidate.values[field]),
      )
      .map((other) => sourceFamily(other.provider.id)),
  ).size;
  reasons.push(
    `${agreement} other sources agree on this title and value; sources may share data`,
  );
  let score = Math.min(
    cap,
    Math.round(
      possible ? (earned / possible) * 90 + Math.min(agreement, 2) * 2 : 0,
    ),
  );
  if (field && !hasHealthValue(candidate.values[field])) {
    score = 0;
    reasons.push("Requested field absent");
  } else if (field)
    reasons.push("Requested field supplied; availability adds no confidence");
  reasons.push("Evidence estimate, not a calibrated probability");
  return { score, reasons };
}

/** Search responses use several provider shapes. Never turn ratings into identity evidence. */
export function healthCandidate(
  provider: ProviderDefinition,
  raw: Record<string, unknown>,
): HealthMatch | undefined {
  const c = { ...raw, ...((raw.fields as Record<string, unknown>) ?? {}) };
  const first = (...keys: string[]) =>
    keys.map((key) => c[key]).find(hasHealthValue);
  const values: Record<string, unknown> = {};
  const put = (key: string, value: unknown) => {
    if (hasHealthValue(value)) values[key] = value;
  };
  put("title", first("editionTitle", "title", "name", "fileName"));
  if (!values.title) return undefined;
  put("mediaType", c.mediaType);
  put("authors", first("artist", "authors"));
  put("year", first("publishYear", "year", "firstPublishYear"));
  put("publisher", first("label", "publisher", "publishers"));
  put("description", first("overview", "description"));
  if (provider.id !== "tmdb")
    put("genres", first("genres", "subjects", "categories"));
  const languages = c.languages;
  // Several languages in a work search are editions, not one language to select.
  put(
    "language",
    c.language ??
      (Array.isArray(languages) && languages.length === 1
        ? language(languages[0])
        : undefined),
  );
  put("premiereDate", first("releaseDate", "publishDate", "publishedDate"));
  const isbnValue = first("isbn", "isbn13", "isbn10");
  if (isbn(isbnValue)) put("isbn", isbnValue);
  for (const key of [
    "narrators",
    "series",
    "volumeNumber",
    "trackNumber",
    "season",
    "episode",
    "runtimeMinutes",
    "subtitle",
  ])
    put(key, c[key] ?? (key === "subtitle" ? c.fileName : undefined));
  const providerIds = {
    ...((raw.providerIds as Record<string, unknown>) ?? {}),
  };
  for (const [key, value] of Object.entries({
    tmdb: c.tmdbId,
    "google-books": c.volumeId,
    "open-library-work": c.workId,
    "open-library-edition": c.editionId,
    "musicbrainz-release-group": c.releaseGroupId,
    "musicbrainz-release": c.releaseId,
    imdb: (c.externalIds as Record<string, unknown>)?.imdbId,
    wikidata: (c.externalIds as Record<string, unknown>)?.wikidataId,
  }))
    if (hasHealthValue(value)) providerIds[key] = value;
  return {
    title: String(values.title),
    values,
    provider,
    providerIds,
    scope:
      provider.id === "open-library"
        ? c.editionId
          ? "edition"
          : "work"
        : undefined,
    matchMethod: typeof c.matchMethod === "string" ? c.matchMethod : undefined,
  };
}
export function rankHealthCandidates(
  candidates: HealthMatch[],
  context: Record<string, unknown>,
  field: string,
): RankedHealthMatch[] {
  return candidates
    .map((candidate) => ({
      ...candidate,
      confidence: matchConfidence(candidate, context, field, candidates),
    }))
    .filter((candidate) => candidate.confidence.score >= MIN_HEALTH_MATCH)
    .sort(
      (a, b) =>
        b.confidence.score - a.confidence.score ||
        a.title.localeCompare(b.title) ||
        a.provider.id.localeCompare(b.provider.id),
    );
}
export function automaticHealthMatch(
  matches: RankedHealthMatch[],
  field: string,
): RankedHealthMatch | undefined {
  const best = matches[0];
  if (!best || best.confidence.score < AUTO_HEALTH_MATCH) return undefined;
  const rival = matches.find(
    (other) => !sameField(field, best.values[field], other.values[field]),
  );
  return rival && best.confidence.score - rival.confidence.score < 10
    ? undefined
    : best;
}
