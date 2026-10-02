// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  buildShuffleOrder,
  decideAdvance,
  endActionFrom,
  endActionSettings,
  nextShuffleScope,
  queueStep,
  shufflePoolIndices,
} from "./playback-queue";
import type { QueueTrack } from "./playback-queue";

const track = (
  id: string,
  relativePath: string,
  mediaKind = "music",
): QueueTrack => ({ id, relativePath, mediaKind });

// A personal music album, a shared music album and an audiobook, so the pools
// can be checked against both the album boundary and the file-type boundary.
const tracks: QueueTrack[] = [
  track("m1", "Music/Blue/01 - One.mp3"),
  track("m2", "Music/Blue/02 - Two.mp3"),
  track("m3", "Music/Green/01 - Three.mp3"),
  track("s1", "Shared/Shared Album/01 - Four.mp3"),
  track("s2", "Shared/Shared Album/02 - Five.mp3"),
  track("a1", "Books/Novel/01 - Chapter 1.m4b", "audiobook"),
  track("a2", "Books/Novel/02 - Chapter 2.m4b", "audiobook"),
];

// Deterministic descending sequence keeps Fisher-Yates predictable: it swaps
// every element with the last one.
const descending = (() => {
  let value = 0.95;
  return () => {
    value -= 0.2;
    return value < 0 ? value + 1 : value;
  };
})();

describe("shuffle scope cycling", () => {
  it("walks off, album, all and back to off", () => {
    expect(nextShuffleScope("off")).toBe("album");
    expect(nextShuffleScope("album")).toBe("all");
    expect(nextShuffleScope("all")).toBe("off");
  });
});

describe("shuffle pools", () => {
  it("keeps an album shuffle inside the current album folder", () => {
    expect(shufflePoolIndices(tracks, 0, "album")).toEqual([1]);
    expect(shufflePoolIndices(tracks, 1, "album")).toEqual([0]);
  });

  it("keeps an album shuffle out of another root's album with the same folder name", () => {
    const sameName = [
      track("p", "Personal/Album/01.mp3"),
      track("s", "Shared/Album/01.mp3"),
    ];
    expect(shufflePoolIndices(sameName, 0, "album")).toEqual([]);
    expect(shufflePoolIndices(sameName, 0, "all")).toEqual([1]);
  });

  it("crosses personal and shared roots but never the file type", () => {
    const pool = shufflePoolIndices(tracks, 0, "all");
    expect(pool).toEqual([1, 2, 3, 4]);
    expect(pool).not.toContain(5);
    expect(pool).not.toContain(6);
  });

  it("pools audiobooks only with audiobooks", () => {
    expect(shufflePoolIndices(tracks, 5, "all")).toEqual([6]);
  });

  it("has no pool when shuffle is off or nothing is selected", () => {
    expect(shufflePoolIndices(tracks, 0, "off")).toEqual([]);
    expect(shufflePoolIndices(tracks, -1, "all")).toEqual([]);
  });
});

describe("shuffled order", () => {
  it("starts at the current track and then covers its pool once", () => {
    const order = buildShuffleOrder(tracks, 0, "all", descending);
    expect(order[0]).toBe(0);
    expect([...order].sort((a, b) => a - b)).toEqual([0, 1, 2, 3, 4]);
  });

  it("builds no order when shuffle is off", () => {
    expect(buildShuffleOrder(tracks, 0, "off", descending)).toEqual([]);
  });
});

describe("queue stepping", () => {
  it("follows the listed order without a shuffle order", () => {
    expect(queueStep(tracks, [], 0, "off", 1).index).toBe(1);
    expect(queueStep(tracks, [], 0, "off", -1).index).toBe(6);
  });

  it("falls back to the listed order for a track the order omits", () => {
    const order = buildShuffleOrder(tracks, 0, "all", descending);
    expect(queueStep(tracks, order, 6, "all", 1).index).toBe(0);
  });

  it("reports wrapping at the end of a shuffled order", () => {
    const order = [0, 2, 1];
    expect(queueStep(tracks, order, 1, "all", 1)).toEqual({
      index: 0,
      wrapped: true,
    });
    expect(queueStep(tracks, order, 1, "all", -1)).toEqual({
      index: 2,
      wrapped: false,
    });
  });
});

describe("what happens when a track ends", () => {
  const base = {
    tracks,
    order: [] as number[],
    currentIndex: 0,
    shuffleScope: "off" as const,
    stopAfterCurrent: false,
    loop: "off" as const,
  };

  it("plays on into the queue", () => {
    expect(decideAdvance(base)).toEqual({
      kind: "advance",
      index: 1,
      wrapped: false,
    });
  });

  it("stays on the current track when stop after this track is set", () => {
    expect(decideAdvance({ ...base, stopAfterCurrent: true })).toEqual({
      kind: "stop",
    });
  });

  it("prefers stopping over repeating the track", () => {
    expect(
      decideAdvance({
        ...base,
        stopAfterCurrent: true,
        loop: "one" as const,
      }),
    ).toEqual({ kind: "stop" });
  });

  it("repeats the track on loop one", () => {
    expect(decideAdvance({ ...base, loop: "one" })).toEqual({
      kind: "repeat-one",
    });
  });

  it("stops at the last track instead of wrapping", () => {
    expect(decideAdvance({ ...base, currentIndex: tracks.length - 1 })).toEqual(
      { kind: "stop" },
    );
  });

  it("wraps to the first track when the queue repeats", () => {
    expect(
      decideAdvance({
        ...base,
        currentIndex: tracks.length - 1,
        loop: "all" as const,
      }),
    ).toEqual({ kind: "advance", index: 0, wrapped: true });
  });

  it("stops at the end of a shuffled order and wraps it on repeat", () => {
    const order = [0, 2, 1];
    expect(
      decideAdvance({
        ...base,
        order,
        shuffleScope: "all",
        currentIndex: 1,
      }),
    ).toEqual({ kind: "stop" });
    expect(
      decideAdvance({
        ...base,
        order,
        shuffleScope: "all",
        currentIndex: 1,
        loop: "all",
      }),
    ).toEqual({ kind: "advance", index: 0, wrapped: true });
  });

  it("never leaves the file type, even when the queue repeats", () => {
    const mixed = [
      track("m1", "Music/Blue/01 - One.mp3"),
      track("a1", "Books/Novel/01 - Chapter 1.m4b", "audiobook"),
      track("a2", "Books/Novel/02 - Chapter 2.m4b", "audiobook"),
    ];
    const order = buildShuffleOrder(mixed, 1, "all", descending);
    expect(order).toEqual([1, 2]);
    expect(
      decideAdvance({
        tracks: mixed,
        order,
        currentIndex: 1,
        shuffleScope: "all",
        stopAfterCurrent: false,
        loop: "all",
      }),
    ).toEqual({ kind: "advance", index: 2, wrapped: false });
    expect(
      decideAdvance({
        tracks: mixed,
        order,
        currentIndex: 2,
        shuffleScope: "all",
        stopAfterCurrent: false,
        loop: "all",
      }),
    ).toEqual({ kind: "advance", index: 1, wrapped: true });
  });
});

describe("end-of-track settings", () => {
  it("maps the pair of controls onto one readable action", () => {
    expect(endActionFrom(false, "off")).toBe("next");
    expect(endActionFrom(true, "off")).toBe("stop");
    expect(endActionFrom(false, "one")).toBe("repeat-one");
    expect(endActionFrom(false, "all")).toBe("repeat-all");
  });

  it("keeps the two controls from disagreeing", () => {
    expect(endActionSettings("stop")).toEqual({
      stopAfterCurrent: true,
      loop: "off",
    });
    expect(endActionSettings("repeat-all")).toEqual({
      stopAfterCurrent: false,
      loop: "all",
    });
    expect(endActionSettings("next")).toEqual({
      stopAfterCurrent: false,
      loop: "off",
    });
  });
});
