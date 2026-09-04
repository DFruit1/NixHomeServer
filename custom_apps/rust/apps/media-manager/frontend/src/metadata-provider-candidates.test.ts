import { describe, expect, it } from "vitest";
import {
  googleBooksMetadataMatchCandidate,
  musicMetadataMatchCandidate,
  tmdbMetadataMatchCandidate,
} from "./metadata-provider-candidates";

describe("provider candidate normalization", () => {
  it("preserves exact MusicBrainz release and release-group identifiers", () => {
    const candidate = musicMetadataMatchCandidate("item-1", {
      releaseGroupId: "1b022e01-4da6-387b-8658-8678046e4cef",
      releaseId: "2d4b4f36-bbf7-37d2-8c59-8f84a8f1b5a7",
      artist: "Nirvana",
      title: "Nevermind",
      releaseDate: "1991-09-24",
      year: 1991,
      genres: ["grunge"],
      label: "DGC",
      barcode: "720642442524",
      matchMethod: "search",
    });
    expect(candidate?.providerIds).toMatchObject({
      musicbrainz: "2d4b4f36-bbf7-37d2-8c59-8f84a8f1b5a7",
      "musicbrainz-release": "2d4b4f36-bbf7-37d2-8c59-8f84a8f1b5a7",
      "musicbrainz-release-group": "1b022e01-4da6-387b-8658-8678046e4cef",
      barcode: "720642442524",
    });
    expect(candidate?.fields.premiereDate).toBe("1991-09-24");
  });

  it("maps Google Books fields without accepting provider image URLs", () => {
    const candidate = googleBooksMetadataMatchCandidate("item-2", {
      volumeId: "zyTCAlFPjgYC",
      title: "Dune",
      authors: ["Frank Herbert"],
      publisher: "Ace",
      year: 1965,
      isbn: "9780441172719",
      language: "en",
      categories: ["Fiction"],
      description: "A desert world.",
      coverAvailable: true,
    });
    expect(candidate?.fields).toMatchObject({
      title: "Dune",
      authors: "Frank Herbert",
      isbn: "9780441172719",
      description: "A desert world.",
    });
    expect(candidate?.providerIds).toEqual({ "google-books": "zyTCAlFPjgYC" });
  });

  it("maps an exact TMDB episode and retains its series identifier", () => {
    const candidate = tmdbMetadataMatchCandidate("item-3", {
      mediaType: "episode",
      tmdbId: 63056,
      seriesTmdbId: 1437,
      seriesTitle: "Firefly",
      title: "The Train Job",
      episodeTitle: "The Train Job",
      season: 1,
      episode: 2,
      runtimeMinutes: 44,
      airDate: "2002-09-20",
    });
    expect(candidate?.fields).toMatchObject({
      mediaType: "episode",
      series: "Firefly",
      season: "1",
      episode: "2",
      episodeTitle: "The Train Job",
      runtimeMinutes: "44",
    });
    expect(candidate?.providerIds).toEqual({
      tmdb: "63056",
      "tmdb-series": "1437",
    });
  });
});
