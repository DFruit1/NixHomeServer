// @vitest-environment node

import { describe, expect, it } from "vitest";
import { catalogItemMatchesTarget, findTargetIndex } from "./playback-target";

const tracks = [
  { id: "a", relativePath: "_YouTube/Alpha/01 - Intro.flac" },
  { id: "b", relativePath: "_YouTube/Beta/01 - Intro.flac" },
  { id: "c", relativePath: "Shared/Singles/03 - Song.mp3" },
];

describe("playback target matching", () => {
  it("matches a deep link by durable item id", () => {
    expect(findTargetIndex(tracks, "b")).toBe(1);
  });

  it("matches a deep link by relative path suffix", () => {
    expect(findTargetIndex(tracks, undefined, "Beta/01 - Intro.flac")).toBe(1);
    expect(
      findTargetIndex(tracks, undefined, "_YouTube/Beta/01 - Intro.flac"),
    ).toBe(1);
  });

  it("matches a path that is not a suffix of another item", () => {
    expect(
      findTargetIndex(tracks, undefined, "Shared/Singles/03 - Song.mp3"),
    ).toBe(2);
  });

  it("returns -1 when no target is supplied or nothing matches", () => {
    expect(findTargetIndex(tracks)).toBe(-1);
    expect(findTargetIndex(tracks, undefined, "Gamma/missing.flac")).toBe(-1);
  });

  it("does not treat a partial filename as a match", () => {
    expect(catalogItemMatchesTarget(tracks[0]!, undefined, "Intro.flac")).toBe(
      false,
    );
  });
});
