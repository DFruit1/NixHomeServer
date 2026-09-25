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

/**
 * Domains that answer a field only for some media kinds: a missing video
 * subtitle is a subtitle-provider job even though the provider declares the
 * "subtitles" domain instead of "movies".
 */
const FIELD_EXTRA_DOMAINS: Partial<
  Record<MediaKind, Record<string, readonly string[]>>
> = {
  video: { subtitle: ["subtitles"] },
};

const FIELD_DOMAIN_BONUS = 50;

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
 * Sources that hold the field's own domain (subtitle providers for a video
 * subtitle) are added on top of the media kind, and among deployed adapters
 * they outrank the generic ones for that field.
 */
export function candidateSources(
  providers: readonly ProviderDefinition[],
  mediaKind: MediaKind,
  field: string,
): ProviderDefinition[] {
  const domains = DOMAINS_BY_KIND[mediaKind] ?? [];
  const fieldDomains = FIELD_EXTRA_DOMAINS[mediaKind]?.[field] ?? [];
  return providers
    .filter((provider) =>
      provider.mediaDomains.some(
        (domain) => domains.includes(domain) || fieldDomains.includes(domain),
      ),
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
            : 0) +
        (provider.mediaDomains.some((domain) => fieldDomains.includes(domain))
          ? FIELD_DOMAIN_BONUS
          : 0),
    }))
    .sort(
      (left, right) =>
        right.score - left.score ||
        left.provider.name.localeCompare(right.provider.name),
    )
    .map(({ provider }) => provider);
}
