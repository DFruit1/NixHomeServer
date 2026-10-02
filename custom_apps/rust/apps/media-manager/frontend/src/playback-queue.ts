import type { CatalogItem } from "./root-types";

export type QueueTrack = Pick<CatalogItem, "id" | "relativePath" | "mediaKind">;

/**
 * How far a shuffled queue reaches. `album` stays inside the current track's
 * folder, `all` reaches every loaded track of the same media kind, so a music
 * track can cross from a personal root to a shared music root but never jumps
 * into an audiobook.
 */
export type ShuffleScope = "off" | "album" | "all";

export type LoopMode = "off" | "one" | "all";

/** What the player does when the current track finishes on its own. */
export type EndOfTrackAction = "next" | "stop" | "repeat-one" | "repeat-all";

export const SHUFFLE_SCOPES: ShuffleScope[] = ["off", "album", "all"];

export const SLEEP_CHOICES: number[] = [0, 15, 30, 45, 60];

/**
 * The transport button cycles through all three states so a single press
 * reaches a shuffled album, a second press widens it to the whole file type,
 * and a third press turns shuffle off again.
 */
export function nextShuffleScope(scope: ShuffleScope): ShuffleScope {
  const index = SHUFFLE_SCOPES.indexOf(scope);
  return SHUFFLE_SCOPES[(index + 1) % SHUFFLE_SCOPES.length] ?? "off";
}

export function albumDirectory(track: QueueTrack): string {
  const parts = track.relativePath.split("/");
  parts.pop();
  return parts.join("/");
}

export function albumName(track: QueueTrack): string {
  const directory = albumDirectory(track);
  if (!directory) return "";
  return directory.split("/").at(-1) ?? directory;
}

/**
 * Track indices a shuffle may visit from `currentIndex`, excluding the current
 * track itself so enabling shuffle never interrupts or repeats what is already
 * playing.
 */
export function shufflePoolIndices(
  tracks: QueueTrack[],
  currentIndex: number,
  scope: ShuffleScope,
): number[] {
  if (scope === "off" || currentIndex < 0 || currentIndex >= tracks.length) {
    return [];
  }
  const current = tracks[currentIndex];
  if (!current) return [];
  const album = albumDirectory(current);
  const pool: number[] = [];
  tracks.forEach((track, index) => {
    if (index === currentIndex) return;
    if (track.mediaKind !== current.mediaKind) return;
    if (scope === "album" && albumDirectory(track) !== album) return;
    pool.push(index);
  });
  return pool;
}

/**
 * A shuffled play order starting at the current track, so turning shuffle on
 * mid-track keeps playing and then wanders the pool.
 */
export function buildShuffleOrder(
  tracks: QueueTrack[],
  currentIndex: number,
  scope: ShuffleScope,
  random: () => number = Math.random,
): number[] {
  if (currentIndex < 0 || currentIndex >= tracks.length) return [];
  if (scope === "off") return [];
  const rest = shufflePoolIndices(tracks, currentIndex, scope);
  for (let i = rest.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    const swap = rest[i] as number;
    rest[i] = rest[j] as number;
    rest[j] = swap;
  }
  return [currentIndex, ...rest];
}

export interface QueueStep {
  index: number;
  /** True when the step ran past the end of the queue and wrapped to its start. */
  wrapped: boolean;
}

/**
 * The order the player should follow for the current track. A shuffled order
 * survives across tracks so the queue keeps its shape, and is only rebuilt when
 * it is missing, empty, or playback moves to a track it does not contain.
 */
export function shuffleOrderFor(
  tracks: QueueTrack[],
  currentIndex: number,
  scope: ShuffleScope,
  existing: number[],
  random: () => number = Math.random,
): number[] {
  if (scope === "off" || currentIndex < 0 || currentIndex >= tracks.length) {
    return [];
  }
  if (existing.includes(currentIndex)) return existing;
  return buildShuffleOrder(tracks, currentIndex, scope, random);
}

/**
 * A random start track inside the pool the active scope allows, so "Play all"
 * under shuffle does not always begin on the first listed track.
 */
export function randomPoolStart(
  tracks: QueueTrack[],
  fallbackIndex: number,
  scope: ShuffleScope,
  random: () => number = Math.random,
): number {
  const pool = shufflePoolIndices(tracks, fallbackIndex, scope);
  if (pool.length === 0) return fallbackIndex;
  return pool[Math.floor(random() * pool.length)] ?? fallbackIndex;
}

/**
 * One step along the play order. Shuffle follows the built order; a track the
 * order does not contain (picked from the sidebar after the order was built)
 * falls back to the listed order instead of stalling.
 */
export function queueStep(
  tracks: QueueTrack[],
  order: number[],
  currentIndex: number,
  shuffleScope: ShuffleScope,
  direction: 1 | -1,
): QueueStep {
  const total = tracks.length;
  if (total === 0) return { index: -1, wrapped: false };
  const listed = (): QueueStep => {
    const index = (((currentIndex + direction) % total) + total) % total;
    return {
      index,
      wrapped: direction === 1 ? index === 0 : index === total - 1,
    };
  };
  if (shuffleScope === "off" || order.length === 0) return listed();
  const position = order.indexOf(currentIndex);
  if (position < 0) return { ...listed(), wrapped: false };
  const size = order.length;
  const next = (((position + direction) % size) + size) % size;
  const index = order[next];
  if (index == null) return { ...listed(), wrapped: false };
  return { index, wrapped: direction === 1 ? next === 0 : next === size - 1 };
}

export function endActionFrom(
  stopAfterCurrent: boolean,
  loop: LoopMode,
): EndOfTrackAction {
  if (stopAfterCurrent) return "stop";
  if (loop === "one") return "repeat-one";
  if (loop === "all") return "repeat-all";
  return "next";
}

export function endActionSettings(action: EndOfTrackAction): {
  stopAfterCurrent: boolean;
  loop: LoopMode;
} {
  return {
    stopAfterCurrent: action === "stop",
    loop: action === "repeat-all" ? "all" : "off",
  };
}

export type AdvanceDecision =
  | { kind: "stop" }
  | { kind: "repeat-one" }
  | { kind: "advance"; index: number; wrapped: boolean };

/**
 * Resolves what happens when a track ends by itself. Manual skips ignore this
 * and always move, so "stop after this track" only suppresses autoplay.
 */
export function decideAdvance(args: {
  tracks: QueueTrack[];
  order: number[];
  currentIndex: number;
  shuffleScope: ShuffleScope;
  stopAfterCurrent: boolean;
  loop: LoopMode;
}): AdvanceDecision {
  const { tracks, order, currentIndex, shuffleScope, stopAfterCurrent, loop } =
    args;
  const action = endActionFrom(stopAfterCurrent, loop);
  if (action === "stop") return { kind: "stop" };
  if (action === "repeat-one") return { kind: "repeat-one" };
  const step = queueStep(tracks, order, currentIndex, shuffleScope, 1);
  if (step.index < 0) return { kind: "stop" };
  if (step.wrapped && action !== "repeat-all") return { kind: "stop" };
  return { kind: "advance", index: step.index, wrapped: step.wrapped };
}
