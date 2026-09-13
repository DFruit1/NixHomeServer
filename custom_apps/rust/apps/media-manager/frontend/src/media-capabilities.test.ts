import { describe, expect, it } from "vitest";
import type { Status } from "./api-contract.generated";
import {
  isLibraryKind,
  mediaKindForMediaType,
  mediaKindProfile,
  supportsMediaAction,
} from "./media-capabilities";
import { wireJson } from "./test-support/wire-fixtures";

function status(): Status {
  return JSON.parse(
    wireJson({ mutationMode: "enabled", integrations: [] }),
  ) as Status;
}

describe("media capabilities", () => {
  it("reports every media kind from the status payload", () => {
    const profiles = status().mediaKinds;
    expect(profiles.map((profile) => profile.kind)).toEqual([
      "video",
      "music",
      "audiobook",
      "podcast",
      "book",
      "artwork",
      "subtitle",
      "iso",
    ]);
  });

  it("offers inline playback for audio but not video or podcast", () => {
    const state = status();
    expect(supportsMediaAction(state, "music", "play-inline")).toBe(true);
    expect(supportsMediaAction(state, "audiobook", "play-inline")).toBe(true);
    expect(supportsMediaAction(state, "video", "play-inline")).toBe(false);
    expect(supportsMediaAction(state, "podcast", "play-inline")).toBe(false);
  });

  it("reserves subtitle management for video", () => {
    const state = status();
    expect(supportsMediaAction(state, "video", "manage-subtitles")).toBe(true);
    expect(supportsMediaAction(state, "music", "manage-subtitles")).toBe(false);
  });

  it("separates library items from companions and containers", () => {
    const state = status();
    expect(isLibraryKind(state, "video")).toBe(true);
    expect(isLibraryKind(state, "audiobook")).toBe(true);
    expect(isLibraryKind(state, "artwork")).toBe(false);
    expect(isLibraryKind(state, "subtitle")).toBe(false);
    expect(isLibraryKind(state, "iso")).toBe(false);
  });

  it("returns no profile for an unknown kind", () => {
    expect(mediaKindProfile(status(), "unknown")).toBeUndefined();
    expect(mediaKindProfile(status(), undefined)).toBeUndefined();
  });

  it("maps editor media types to their catalog kind", () => {
    expect(mediaKindForMediaType("movie")).toBe("video");
    expect(mediaKindForMediaType("series")).toBe("video");
    expect(mediaKindForMediaType("season")).toBe("video");
    expect(mediaKindForMediaType("episode")).toBe("video");
    expect(mediaKindForMediaType("music")).toBe("music");
    expect(mediaKindForMediaType("audiobook")).toBe("audiobook");
    expect(mediaKindForMediaType("podcast")).toBe("podcast");
    expect(mediaKindForMediaType("book")).toBe("book");
  });

  it("returns no catalog kind for grouping labels and unknown types", () => {
    expect(mediaKindForMediaType("collection")).toBeUndefined();
    expect(mediaKindForMediaType("unexpected")).toBeUndefined();
    expect(mediaKindForMediaType(undefined)).toBeUndefined();
  });
});
