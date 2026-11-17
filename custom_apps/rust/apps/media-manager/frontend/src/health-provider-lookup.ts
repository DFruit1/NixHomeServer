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
  "thediscdb",
  "tvmaze",
  "anilist",
  "deezer",
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
/** Identifiers lead an unchanged item query; a user's edited query stays literal.
 * Empty identifier searches get one title/creator fallback, never an error retry.
 * https://developers.google.com/books/docs/v1/using#PerformingSearch
 */
export function healthLookupQueries(
  provider: string,
  query: string,
  context: Record<string, unknown>,
): string[] {
  if (
    !["open-library", "google-books", "isbndb"].includes(provider) ||
    normalized(query) !== normalized(context.title)
  )
    return [query];
  const identifier = isbnFromContext(context);
  const authors = searchAuthors(context);
  const author = Array.isArray(authors) ? authors[0] : authors;
  const quote = (value: unknown) =>
    String(value ?? "")
      .replace(/[\\"]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  const focused = hasHealthValue(author)
    ? provider === "google-books"
      ? `intitle:"${quote(query)}" inauthor:"${quote(author)}"`
      : provider === "open-library"
        ? `title:"${quote(query)}" author:"${quote(author)}"`
        : `${query} ${quote(author)}`
    : query;
  const fallback = focused.length <= 500 ? focused : query;
  return [
    ...new Set(
      identifier
        ? [provider === "isbndb" ? identifier : `isbn:${identifier}`, fallback]
        : [fallback, query],
    ),
  ];
}
/** Known authors, else the author named by the item's folder. */
function searchAuthors(context: Record<string, unknown>): unknown {
  return hasHealthValue(context.authors)
    ? context.authors
    : context.folderAuthor;
}
/**
 * True when listed authors share the folder's name people file by: the
 * surname, or the given name in "Augustine of Hippo" ("Saint Augustine").
 */
export function matchesFolderAuthor(
  authors: unknown,
  folder: unknown,
): boolean {
  if (!hasHealthValue(authors) || !hasHealthValue(folder)) return false;
  const words = normalized(folder).split(" ");
  const of = words.indexOf("of");
  const key = of > 0 ? words[of - 1] : words.at(-1);
  return !!key && normalized(authors).split(" ").includes(key);
}
/** A folder guess only narrows a search; it never hides title-only results. */
export async function lookupHealthProvider(
  provider: string,
  query: string,
  itemId: string,
  context: Record<string, unknown>,
): Promise<Record<string, unknown>[]> {
  const results = await lookupOnce(provider, query, itemId, context);
  if (hasHealthValue(context.authors) || !hasHealthValue(context.folderAuthor))
    return results;
  const supported = results.some((row) => {
    const fields = (row.fields as Record<string, unknown>) ?? {};
    return matchesFolderAuthor(
      row.authors ?? row.artist ?? fields.authors ?? fields.artist,
      context.folderAuthor,
    );
  });
  if (supported) return results;
  const titleOnly = await lookupOnce(provider, query, itemId, {
    ...context,
    folderAuthor: undefined,
  });
  return titleOnly.length ? titleOnly : results;
}
async function lookupOnce(
  provider: string,
  query: string,
  itemId: string,
  context: Record<string, unknown>,
): Promise<Record<string, unknown>[]> {
  const music = provider === "musicbrainz" || provider === "acoustid";
  const authors = searchAuthors(context);
  for (const lookupQuery of healthLookupQueries(provider, query, context)) {
    const body = music
      ? {
          mode: provider === "acoustid" ? "fingerprint" : "search",
          title: lookupQuery,
          ...(hasHealthValue(authors)
            ? {
                artist: Array.isArray(authors)
                  ? authors.join(", ")
                  : String(authors),
              }
            : {}),
        }
      : provider === "tmdb"
        ? { query: lookupQuery, mediaType: "auto" }
        : provider === "opensubtitles"
          ? { query: lookupQuery, languages: String(context.language || "en") }
          : provider === "audnexus"
            ? { id: (context.providerIds as Record<string, unknown>).asin }
            : { query: lookupQuery };
    const response = await api<{
      results?: Record<string, unknown>[];
      candidates?: Record<string, unknown>[];
    }>(
      music
        ? `/items/${encodeURIComponent(itemId)}/metadata/lookup`
        : `/provider-lookups/${provider}/search`,
      { method: "POST", body: JSON.stringify(body) },
    );
    const results = response.results ?? response.candidates ?? [];
    if (results.length) return results;
  }
  return [];
}

export const MIN_HEALTH_MATCH = 30;
export const AUTO_HEALTH_MATCH = 75;

/** Plain wording for an evidence score; the number stays secondary. */
export function matchLabel(score: number): string {
  return score >= AUTO_HEALTH_MATCH
    ? "Good match"
    : score >= 50
      ? "Possible match"
      : "Weak match";
}

const EVIDENCE_NAMES: Record<string, string> = {
  title: "Title",
  mediaType: "Kind of media",
  authors: "Author",
  year: "Year",
  language: "Language",
  publisher: "Publisher",
  series: "Series",
  volumeNumber: "Volume number",
  season: "Season",
  episode: "Episode",
  isbn: "ISBN",
};

export interface HealthMatch {
  title: string;
  provider: ProviderDefinition;
  values: Record<string, unknown>;
  providerIds: Record<string, unknown>;
  scope?: "work" | "edition";
  matchMethod?: string;
  detailError?: string;
  detailsPending?: boolean;
  editionsTruncated?: boolean;
}
export interface MatchEvidence {
  identified: boolean;
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
function titleIdentity(value: unknown): string {
  return normalized(value).replace(
    /\b(book|vol(?:ume)?|part|disc|season|episode)\s+(\d+|[ivxlcdm]+)\b/g,
    (match) => numberedTitle(match)[0]?.replace(":", " ") ?? match,
  );
}
function titleSimilarity(a: unknown, b: unknown): number {
  const full = similarity(titleIdentity(a), titleIdentity(b));
  const primary = (v: unknown) =>
    titleIdentity(String(v ?? "").split(/[:—–]|\s-\s/)[0]);
  const x = primary(a),
    y = primary(b);
  return x === y && x.length >= 8 && x.split(" ").length >= 2
    ? Math.max(full, 0.92)
    : full;
}
function numberedTitle(value: unknown): string[] {
  const text = normalized(value);
  const markers = [
    ...text.matchAll(
      /\b(book|vol(?:ume)?|part|disc|season|episode)\s+(\d+|[ivxlcdm]+)\b/g,
    ),
  ];
  return markers.flatMap((match) => {
    const roman = match[2];
    const valid =
      /^(?=.)m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$/.test(
        roman,
      );
    if (!/^\d+$/.test(roman) && !valid) return [];
    const digits: Record<string, number> = {
      i: 1,
      v: 5,
      x: 10,
      l: 50,
      c: 100,
      d: 500,
      m: 1000,
    };
    const number = /^\d+$/.test(roman)
      ? Number(roman)
      : [...roman].reduce(
          (sum, c, index) =>
            sum +
            (digits[c] < (digits[roman[index + 1]] ?? 0)
              ? -digits[c]
              : digits[c]),
          0,
        );
    return [
      `${["book", "vol", "volume"].includes(match[1]) ? "volume" : match[1]}:${number}`,
    ];
  });
}
const EDITION_FIELDS = new Set([
  "title",
  "year",
  "language",
  "publisher",
  "isbn",
  "narrators",
  "volumeNumber",
]);
const PRECISE_IDS = new Set([
  "asin",
  "imdb",
  "tmdb",
  "google-books",
  "open-library-edition",
  "musicbrainz-release",
  "barcode",
]);
function identifier(key: string, value: unknown): string {
  if (typeof value !== "string" && typeof value !== "number") return "";
  const text = String(value).trim().normalize("NFC");
  // Volume IDs and other opaque IDs retain case and punctuation.
  if (key === "asin" || key.startsWith("open-library-"))
    return text.toUpperCase();
  if (key === "imdb" || key.startsWith("musicbrainz-"))
    return text.toLowerCase();
  return text;
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
function languageCode(value: unknown): string {
  const [base, ...region] = String(value ?? "")
    .trim()
    .toLowerCase()
    .replaceAll("_", "-")
    .split("-");
  const code = [LANGUAGES[base] ?? base, ...region].join("-");
  return /^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/.test(code) ? code : "";
}
function language(value: unknown): string {
  return languageCode(value).split("-")[0];
}
/** ISBN-10 and ISBN-13 identify editions, not the umbrella work. Validate checksums. */
function isbn(value: unknown): string {
  let text = String(value ?? "")
    .replace(/^isbn(?:[-\s]?1[03])?\s*:?\s*/i, "")
    .replace(/[\s-]/g, "")
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
  if (!/^97[89]\d{10}$/.test(text)) return "";
  return [...text].reduce((s, c, i) => s + Number(c) * (i % 2 ? 3 : 1), 0) % 10
    ? ""
    : text;
}
function isbnFromContext(context: Record<string, unknown>): string {
  const ids = context.providerIds as Record<string, unknown> | undefined;
  return isbn(context.isbn) || isbn(ids?.isbn13) || isbn(ids?.isbn10);
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
  if (field === "language") return !!language(a) && language(a) === language(b);
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
  basis?: ReadonlyMap<HealthMatch, MatchEvidence>,
): MatchEvidence {
  let earned = 0,
    possible = 0,
    supporting = 0,
    identityMatches = 0,
    identityConflicts = 0,
    editionMatches = 0,
    providerMatches = 0;
  const reasons: string[] = [];
  let cap = 95;
  const referenceISBN = isbnFromContext(context);
  const compare = (key: string, weight: number) => {
    const reference = key === "isbn" ? referenceISBN : context[key];
    if (
      key === "year" &&
      candidate.scope === "work" &&
      ["authors", "series"].includes(field)
    ) {
      reasons.push("The first publication year doesn't identify this edition");
      return;
    }
    // Do not use the value we are trying to discover as evidence for itself.
    if ((key === field && field !== "title") || !hasHealthValue(reference))
      return;
    possible += weight;
    const present = hasHealthValue(candidate.values[key]);
    const match = !present
      ? 0
      : key === "language"
        ? Number(
            !!language(candidate.values[key]) &&
              language(candidate.values[key]) === language(reference),
          )
        : key === "isbn"
          ? Number(
              !!referenceISBN && isbn(candidate.values[key]) === referenceISBN,
            )
          : key === "mediaType"
            ? Number(
                String(candidate.values[key]).replace(/^series$/, "tv") ===
                  String(context[key]).replace(/^series$/, "tv"),
              )
            : key === "title"
              ? titleSimilarity(candidate.values[key], reference)
              : similarity(candidate.values[key], reference);
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
      `${EVIDENCE_NAMES[key] ?? key} ${!present ? "not listed" : match === 1 ? "matches" : match > 0 ? "partly matches" : "differs"}`,
    );
    if (
      key === "isbn" &&
      present &&
      referenceISBN &&
      isbn(candidate.values[key])
    ) {
      if (match === 1) {
        identityMatches++;
        editionMatches++;
      } else identityConflicts++;
    }
    if (present && !match) {
      if (["mediaType", "volumeNumber", "season", "episode"].includes(key))
        cap = Math.min(cap, 29);
      else if (key === "authors") cap = Math.min(cap, 45);
      else if (["year", "language"].includes(key)) cap = Math.min(cap, 65);
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
  if (referenceISBN) compare("isbn", 50);
  // The folder's author is independent of the item's own metadata, so it is
  // evidence even when the author is the field being looked up. A folder name
  // is only a guess (it may be a series), so agreement adds support and
  // disagreement costs nothing.
  if (
    !hasHealthValue(context.authors) &&
    matchesFolderAuthor(candidate.values.authors, context.folderAuthor)
  ) {
    possible += 15;
    earned += 15;
    supporting++;
    reasons.push("Author matches the folder name");
  }
  const ids = context.providerIds as Record<string, unknown> | undefined;
  for (const [key, value] of Object.entries(candidate.providerIds)) {
    if (
      !ID_KEYS.has(key) ||
      !hasHealthValue(ids?.[key]) ||
      !hasHealthValue(value)
    )
      continue;
    const same = identifier(key, ids![key]) === identifier(key, value);
    if (same) {
      identityMatches++;
      providerMatches++;
      if (PRECISE_IDS.has(key)) editionMatches++;
    } else identityConflicts++;
    reasons.push(`${same ? "Same" : "Different"} ${key} ID`);
  }
  const titleMatch = titleSimilarity(candidate.values.title, context.title);
  if (providerMatches) {
    possible += 60;
    earned += 60;
  }
  if (!identityMatches && titleMatch < 0.35) cap = Math.min(cap, 29);
  if (identityConflicts) {
    cap = Math.min(cap, 19);
    reasons.push("Its catalogue ID differs from this item's");
  }
  if (!identityMatches && !supporting) {
    cap = Math.min(cap, 60);
    reasons.push("Only the title could be compared");
  }
  const referenceParts = numberedTitle(context.title),
    candidateParts = numberedTitle(candidate.values.title);
  if (
    referenceParts.some((part) =>
      candidateParts.some(
        (other) => part.split(":")[0] === other.split(":")[0] && part !== other,
      ),
    )
  ) {
    cap = Math.min(cap, 29);
    reasons.push("A different part or volume");
  }
  const abridgement = (v: unknown) =>
    normalized(v).match(/\b(unabridged|abridged)\b/)?.[0];
  if (
    EDITION_FIELDS.has(field) &&
    abridgement(context.title) &&
    abridgement(candidate.values.title) &&
    abridgement(context.title) !== abridgement(candidate.values.title)
  ) {
    cap = Math.min(cap, 29);
    reasons.push("Abridged and unabridged editions differ");
  }
  const identified =
    (EDITION_FIELDS.has(field) ? editionMatches : identityMatches) > 0 &&
    identityConflicts === 0;
  if (
    candidate.detailsPending ||
    (candidate.editionsTruncated && EDITION_FIELDS.has(field) && !identified)
  ) {
    cap = Math.min(cap, 74);
    reasons.push(
      candidate.detailsPending
        ? "Its full details haven't been checked yet"
        : "Only some editions were checked",
    );
  }
  // A fingerprint locates a recording/release group, not a particular edition.
  if (candidate.matchMethod === "fingerprint")
    reasons.push("The audio matches this recording; the release may differ");
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
    reasons.push("General book details can't confirm this edition's value");
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
          titleSimilarity(other.values.title, candidate.values.title) >= 0.8 &&
          (!hasHealthValue(candidate.values.authors) ||
            !hasHealthValue(other.values.authors) ||
            similarity(other.values.authors, candidate.values.authors) >=
              0.8) &&
          hasHealthValue(candidate.values[field]) &&
          sameField(field, other.values[field], candidate.values[field]) &&
          (basis?.get(other) ?? matchConfidence(other, context, field, []))
            .score >= AUTO_HEALTH_MATCH,
      )
      .map((other) => sourceFamily(other.provider.id)),
  ).size;
  if (agreement)
    reasons.push(
      `${agreement} other ${agreement === 1 ? "source agrees" : "sources agree"} (sources may copy each other)`,
    );
  let score = Math.min(
    cap,
    Math.round(
      possible ? (earned / possible) * 90 + Math.min(agreement, 2) * 2 : 0,
    ),
  );
  if (field && !hasHealthValue(candidate.values[field])) {
    score = 0;
    reasons.push(`No ${(EVIDENCE_NAMES[field] ?? field).toLowerCase()} listed`);
  }
  return { score, reasons, identified };
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
    languageCode(
      c.language ??
        (Array.isArray(languages) && languages.length === 1
          ? languages[0]
          : undefined),
    ),
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
  // Cross-source support reuses each candidate's independent evidence instead
  // of rescoring every pair as providers stream into the dialog.
  const basis = new Map(
    candidates.map((candidate) => [
      candidate,
      matchConfidence(candidate, context, field, []),
    ]),
  );
  return candidates
    .map((candidate) => ({
      ...candidate,
      confidence: matchConfidence(candidate, context, field, candidates, basis),
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
  coverage: { failures?: string[]; candidates?: HealthMatch[] } = {},
): { candidate?: RankedHealthMatch; message: string } {
  const best = matches[0];
  if (!best) return { message: "No matching source supplied this value." };
  if (best.confidence.score < AUTO_HEALTH_MATCH)
    return {
      message:
        "The available evidence is too weak to suggest a value automatically.",
    };
  const identified = matches.filter(
    (candidate) =>
      candidate.confidence.identified &&
      candidate.confidence.score >= AUTO_HEALTH_MATCH,
  );
  if (
    identified.some(
      (candidate) =>
        !sameField(field, best.values[field], candidate.values[field]),
    )
  )
    return {
      message:
        "The identifier-matched edition supplies a different value; compare the editions.",
    };
  const trusted = identified.find((candidate) =>
    sameField(field, best.values[field], candidate.values[field]),
  );
  const rival = matches.find(
    (other) => !sameField(field, best.values[field], other.values[field]),
  );
  const selected = trusted ?? best;
  if (rival && selected.confidence.score - rival.confidence.score < 10)
    return {
      message: "Sources disagree on this value; compare the alternatives.",
    };
  if (!trusted && coverage.failures?.length)
    return {
      message:
        "Some sources could not be checked. Retry the provider search before choosing a suggestion.",
    };
  if (
    !trusted &&
    coverage.candidates?.some((candidate) => candidate.detailsPending)
  )
    return {
      message:
        "Other plausible matches still need details. Narrow the provider search or review their editions.",
    };
  return { candidate: selected, message: "" };
}
