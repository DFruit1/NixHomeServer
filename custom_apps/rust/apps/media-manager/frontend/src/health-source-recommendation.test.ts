import { expect, it } from "vitest";
import type { ProviderDefinition } from "./api-contract.generated";
import { candidateSources, sourceStatus } from "./health-source-recommendation";

function provider(overrides: Partial<ProviderDefinition>): ProviderDefinition {
  return {
    id: "sample",
    name: "Sample",
    mediaDomains: [],
    setupKind: "public",
    implementationStatus: "active",
    canConfigure: false,
    canTest: false,
    capabilities: ["search"],
    credentialFields: [],
    setupUrl: "https://example.test/setup",
    documentationUrl: "https://example.test/docs",
    notes: "Sample source.",
    account: { state: "notRequired" },
    ...overrides,
  };
}

const openLibrary = provider({
  id: "open-library",
  name: "Open Library",
  mediaDomains: ["books", "audiobooks"],
  capabilities: ["search", "isbn", "editions", "bibliographic-metadata"],
});

const audnexus = provider({
  id: "audnexus",
  name: "Audnexus",
  mediaDomains: ["audiobooks"],
  implementationStatus: "planned",
  capabilities: ["audiobook-search", "authors", "narrators", "series"],
});

const googleBooks = provider({
  id: "google-books",
  name: "Google Books",
  mediaDomains: ["books"],
  setupKind: "apiKey",
  capabilities: ["search", "isbn", "descriptions"],
  account: { state: "notConfigured" },
});

const tmdb = provider({
  id: "tmdb",
  name: "The Movie Database (TMDB)",
  mediaDomains: ["movies", "television"],
  capabilities: ["search", "details", "people"],
});

it("keeps sources for the media kind and puts the deployed best match first", () => {
  const ranked = candidateSources(
    [audnexus, googleBooks, openLibrary, tmdb],
    "audiobook",
    "authors",
  );
  expect(ranked.map((entry) => entry.id)).toEqual([
    "open-library",
    "google-books",
    "audnexus",
  ]);
});

it("lets a deployed source outrank a planned source that matches the field better", () => {
  const ranked = candidateSources(
    [audnexus, openLibrary],
    "audiobook",
    "narrators",
  );
  expect(ranked[0]?.id).toBe("open-library");
  expect(ranked[1]?.id).toBe("audnexus");
});

it("drops sources that do not cover the media kind", () => {
  expect(candidateSources([tmdb, openLibrary], "music", "title")).toEqual([]);
});

it("describes whether the source still needs setup", () => {
  expect(sourceStatus(openLibrary)).toEqual({
    label: "No setup needed",
    tone: "ready",
  });
  expect(sourceStatus(googleBooks)).toEqual({
    label: "Not set up",
    tone: "idle",
  });
  expect(sourceStatus(audnexus)).toEqual({
    label: "Coming soon",
    tone: "planned",
  });
  expect(sourceStatus(provider({ account: { state: "configured" } }))).toEqual({
    label: "Configured",
    tone: "ready",
  });
});
