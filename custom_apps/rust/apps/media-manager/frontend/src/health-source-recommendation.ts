import type {
  MetadataHealthResult,
  ProviderDefinition,
} from "./api-contract.generated";

type MediaKind = MetadataHealthResult["mediaKind"];

const DOMAINS_BY_KIND: Record<MediaKind, readonly string[]> = {
  video: ["movies", "television"],
  music: ["music"],
  audiobook: ["audiobooks", "books"],
  podcast: ["podcasts"],
  book: ["books"],
};

const CAPABILITIES_BY_FIELD: Record<string, readonly string[]> = {
  title: [
    "search",
    "details",
    "audiobook-search",
    "podcast-search",
    "bibliographic-metadata",
    "releases",
  ],
  authors: ["authors", "people", "bibliographic-metadata", "search"],
  narrators: ["narrators", "authors", "people", "audiobook-search"],
  series: ["series", "seasons", "release-groups", "editions", "feeds"],
  volumeNumber: ["editions", "series", "bibliographic-metadata"],
  trackNumber: [
    "recordings",
    "releases",
    "audio-fingerprint",
    "release-search",
  ],
  chapters: ["audiobook-search", "episodes", "feeds"],
  subtitle: ["search", "subtitle-search"],
  year: ["details", "bibliographic-metadata", "releases", "editions"],
  language: ["editions", "translations", "bibliographic-metadata"],
};

const DEFAULT_CAPABILITIES = ["search", "details", "bibliographic-metadata"];

export interface SourceStatus {
  label: string;
  tone: "ready" | "planned" | "idle";
}

export function sourceStatus(provider: ProviderDefinition): SourceStatus {
  if (provider.implementationStatus === "planned")
    return { label: "Coming soon", tone: "planned" };
  switch (provider.account.state) {
    case "configured":
      return { label: "Configured", tone: "ready" };
    case "notRequired":
      return { label: "No setup needed", tone: "ready" };
    default:
      return { label: "Not set up", tone: "idle" };
  }
}

export function sourceStatusClass(status: SourceStatus): string {
  return status.tone === "idle"
    ? "provider-state"
    : `provider-state ${status.tone}`;
}

function capabilityScore(provider: ProviderDefinition, field: string): number {
  const wanted = CAPABILITIES_BY_FIELD[field] ?? DEFAULT_CAPABILITIES;
  for (let index = 0; index < wanted.length; index++) {
    if (provider.capabilities.includes(wanted[index]))
      return (wanted.length - index) * 10;
  }
  return 0;
}

/**
 * Online metadata sources that cover this media kind, best match first: a
 * deployed adapter always outranks a planned one, then how well its
 * capabilities answer the field, then whether it already works without setup.
 */
export function candidateSources(
  providers: readonly ProviderDefinition[],
  mediaKind: MediaKind,
  field: string,
): ProviderDefinition[] {
  const domains = DOMAINS_BY_KIND[mediaKind] ?? [];
  return providers
    .filter((provider) =>
      provider.mediaDomains.some((domain) => domains.includes(domain)),
    )
    .map((provider) => ({
      provider,
      score:
        (provider.implementationStatus === "active" ? 1000 : 0) +
        capabilityScore(provider, field) +
        (provider.account.state === "configured"
          ? 6
          : provider.account.state === "notRequired"
            ? 3
            : 0),
    }))
    .sort(
      (left, right) =>
        right.score - left.score ||
        left.provider.name.localeCompare(right.provider.name),
    )
    .map(({ provider }) => provider);
}
