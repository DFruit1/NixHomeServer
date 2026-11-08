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
    return "Setup required";
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
  const body = music
    ? { mode: provider === "acoustid" ? "fingerprint" : "search", title: query }
    : provider === "tmdb"
      ? { query, mediaType: "auto" }
      : provider === "opensubtitles"
        ? { query, languages: String(context.language || "en") }
        : provider === "audnexus"
          ? { id: (context.providerIds as Record<string, unknown>).asin }
          : { query };
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
function normalized(value: unknown): string {
  return (Array.isArray(value) ? value.join(" ") : String(value ?? ""))
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
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
interface Match {
  provider: ProviderDefinition;
  values: Record<string, unknown>;
  providerIds: Record<string, unknown>;
}
/** Heuristic evidence score, never an upstream popularity or accuracy rating. */
export function matchConfidence(
  candidate: Match,
  context: Record<string, unknown>,
  field: string,
  candidates: Match[],
) {
  let earned = 0,
    possible = 0;
  const reasons: string[] = [];
  const compare = (key: string, weight: number) => {
    if (!normalized(context[key])) return;
    possible += weight;
    const match = similarity(candidate.values[key], context[key]);
    earned += weight * match;
    reasons.push(
      `${key}: ${!normalized(candidate.values[key]) ? "unavailable" : match === 1 ? "matches" : match > 0 ? "partial match" : "differs"}`,
    );
  };
  compare("title", 40);
  compare("authors", 20);
  compare("year", 10);
  compare("language", 5);
  compare("publisher", 5);
  compare("series", 10);
  compare("volumeNumber", 10);
  compare("isbn", 30);
  const ids = context.providerIds as Record<string, unknown> | undefined;
  for (const [key, value] of Object.entries(candidate.providerIds)) {
    if (!ids?.[key]) continue;
    possible += 35;
    const same = normalized(ids[key]) === normalized(value);
    earned += same ? 35 : 0;
    reasons.push(`${key} identifier ${same ? "matches" : "differs"}`);
  }
  possible += 20;
  if (normalized(candidate.values[field])) earned += 20;
  reasons.push(
    normalized(candidate.values[field])
      ? "Requested field supplied"
      : "Requested field absent",
  );
  const agreement = new Set(
    candidates
      .filter(
        (other) =>
          other.provider.id !== candidate.provider.id &&
          similarity(other.values.title, candidate.values.title) >= 0.8 &&
          normalized(candidate.values[field]) &&
          normalized(other.values[field]) ===
            normalized(candidate.values[field]),
      )
      .map((other) => other.provider.id),
  ).size;
  // Supporting evidence only: sources may share data.
  const score = Math.min(
    95,
    Math.round((earned / possible) * 80 + Math.min(agreement, 3) * 5),
  );
  reasons.push(
    `${agreement} other sources agree on this title and value`,
    "Subjective estimate; sources may share data",
  );
  return { score, reasons };
}
