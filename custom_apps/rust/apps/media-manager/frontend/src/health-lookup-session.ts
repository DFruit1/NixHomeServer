import { api, readableError } from "./api";
import type {
  ProviderDefinition,
  OpenLibraryEditionsResponse,
  TmdbDetailsResponse,
} from "./api-contract.generated";
import { candidateSources } from "./health-source-recommendation";
import {
  healthCandidate,
  healthLookupAvailability,
  lookupHealthProvider,
  matchConfidence,
  type HealthMatch,
} from "./health-provider-lookup";

type Context = Record<string, unknown>;
export interface HealthLookupResult {
  context: Context;
  candidates: HealthMatch[];
  statuses: Record<string, string>;
  failures: string[];
}
/** A single mounted health page owns the cache: no cross-account or persistent data.
 * At most two broker requests run at once; repeated fields reuse each item's
 * metadata, searches and bounded detail requests, including in the manual dialog.
 */
export function createHealthLookupSession() {
  const cache = new Map<string, Promise<unknown>>();
  const waiting: Array<() => void> = [];
  let running = 0;
  let disposed = false;
  const request = async <T>(load: () => Promise<T>): Promise<T> => {
    if (disposed) throw new Error("Lookup cancelled");
    if (running >= 2)
      await new Promise<void>((resolve) => waiting.push(resolve));
    else running++;
    try {
      if (disposed) throw new Error("Lookup cancelled");
      return await load();
    } finally {
      const next = waiting.shift();
      if (next) next();
      else running--;
    }
  };
  const cached = <T>(key: string, load: () => Promise<T>): Promise<T> => {
    const existing = cache.get(key);
    if (existing) return existing as Promise<T>;
    const promise = load().catch((error) => {
      cache.delete(key);
      throw error;
    });
    cache.set(key, promise);
    // Browser-session cache is bounded even when scrolling a very large library.
    if (cache.size > 256) cache.delete(cache.keys().next().value!);
    return promise;
  };
  const metadata = (itemId: string) =>
    cached(`metadata:${itemId}`, () =>
      request(() =>
        api<Context>(`/items/${encodeURIComponent(itemId)}/metadata`),
      ),
    );
  const enrich = (
    provider: ProviderDefinition,
    raw: Context,
  ): Promise<HealthMatch[]> =>
    cached(`details:${provider.id}:${JSON.stringify(raw)}`, async () => {
      const original = healthCandidate(provider, raw);
      if (!original) return [];
      try {
        if (
          provider.id === "tmdb" &&
          raw.tmdbId &&
          ["movie", "tv"].includes(String(raw.mediaType))
        ) {
          const result = await request(() =>
            api<TmdbDetailsResponse>("/provider-lookups/tmdb/details", {
              method: "POST",
              body: JSON.stringify({
                tmdbId: raw.tmdbId,
                mediaType: raw.mediaType,
              }),
            }),
          );
          const detailed = healthCandidate(provider, result.details);
          return detailed ? [detailed] : [original];
        }
        if (provider.id === "open-library" && raw.workId && !raw.editionId) {
          const result = await request(() =>
            api<OpenLibraryEditionsResponse>(
              `/provider-lookups/open-library/works/${encodeURIComponent(String(raw.workId))}/editions?offset=0&limit=12`,
            ),
          );
          return result.results.length
            ? result.results.flatMap((edition) => {
                // Work search publishers/languages/first publication year aggregate
                // many editions. Do not leak those into a specific edition's values.
                const detailed = healthCandidate(provider, {
                  ...raw,
                  ...edition,
                  editionTitle: edition.title,
                  year: null,
                  firstPublishYear: null,
                  publishYear: edition.publishYear ?? null,
                  publisher: null,
                  publishers: edition.publishers ?? [],
                  languages: edition.languages ?? [],
                  isbn: null,
                  isbn10: edition.isbn10 ?? null,
                  isbn13: edition.isbn13 ?? null,
                });
                return detailed ? [detailed] : [];
              })
            : [original];
        }
        const next = raw.next as Context | undefined;
        if (next?.id && next.mediaType) {
          const result = await request(() =>
            api<{ results: Context[] }>(
              `/provider-lookups/${provider.id}/details`,
              {
                method: "POST",
                body: JSON.stringify(next),
              },
            ),
          );
          return result.results.flatMap((row) => {
            const detailed = healthCandidate(provider, row);
            return detailed ? [detailed] : [];
          });
        }
        return [original];
      } catch {
        return [
          {
            ...original,
            detailError: "Detailed edition information could not be checked",
          },
        ];
      }
    });
  const searchProvider = (
    provider: ProviderDefinition,
    query: string,
    itemId: string,
    context: Context,
  ) =>
    cached(`search:${provider.id}:${itemId}:${query}`, async () => {
      const raw = await request(() =>
        lookupHealthProvider(provider.id, query, itemId, context),
      );
      const rows = raw.flatMap((row) => {
        const match = healthCandidate(provider, row);
        return match ? [{ row, match }] : [];
      });
      const best = rows
        .slice()
        .sort(
          (a, b) =>
            matchConfidence(b.match, context, "", []).score -
            matchConfidence(a.match, context, "", []).score,
        )
        .filter(
          ({ match }) => matchConfidence(match, context, "", []).score >= 30,
        )
        .slice(0, 3);
      const details = await Promise.all(
        best.map(({ row }) => enrich(provider, row)),
      );
      return rows.flatMap(({ row, match }) => {
        const index = best.findIndex((best) => best.row === row);
        return index < 0 ? [match] : details[index];
      });
    });
  return {
    metadata,
    dispose() {
      disposed = true;
      cache.clear();
    },
    async search(
      providers: ProviderDefinition[],
      mediaKind: Parameters<typeof candidateSources>[1],
      field: string,
      itemId: string,
      query: string,
      context: Context,
      onProvider?: (
        candidates: HealthMatch[],
        provider: string,
        status: string,
      ) => void,
    ): Promise<HealthLookupResult> {
      const candidates: HealthMatch[] = [];
      const statuses: Record<string, string> = {};
      const failures: string[] = [];
      await Promise.all(
        candidateSources(providers, mediaKind, field).map(async (provider) => {
          const unavailable = healthLookupAvailability(provider, context);
          if (unavailable) {
            statuses[provider.id] = unavailable;
            onProvider?.([], provider.id, unavailable);
            return;
          }
          onProvider?.([], provider.id, "Searching…");
          try {
            const matches = await searchProvider(
              provider,
              query,
              itemId,
              context,
            );
            candidates.push(...matches);
            const status = matches.length ? "" : "No matches";
            statuses[provider.id] = status;
            onProvider?.(matches, provider.id, status);
          } catch (error) {
            statuses[provider.id] = readableError(error);
            failures.push(`${provider.name}: ${statuses[provider.id]}`);
            onProvider?.([], provider.id, statuses[provider.id]);
          }
        }),
      );
      return { context, candidates, statuses, failures };
    },
  };
}
export type HealthLookupSession = ReturnType<typeof createHealthLookupSession>;
