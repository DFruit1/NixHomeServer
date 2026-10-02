import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";

const personalMusic = [
  {
    id: "blue-1",
    rootId: "personal-music",
    relativePath: "Blue Hour/01 - First Light.mp3",
    mediaKind: "music",
    sizeBytes: 1024,
  },
  {
    id: "blue-2",
    rootId: "personal-music",
    relativePath: "Blue Hour/02 - Second Light.mp3",
    mediaKind: "music",
    sizeBytes: 1024,
  },
];

const sharedMusic = [
  {
    id: "shared-1",
    rootId: "shared-music",
    relativePath: "Shared Album/01 - Third Light.mp3",
    mediaKind: "music",
    sizeBytes: 1024,
  },
];

const audiobooks = [
  {
    id: "book-1",
    rootId: "personal-audiobooks",
    relativePath: "Novels/A Novel/01 - Chapter One.m4b",
    mediaKind: "audiobook",
    sizeBytes: 1024,
  },
];

const roots = [
  {
    id: "personal-music",
    label: "My music",
    category: "music",
    scope: "personal",
    available: true,
  },
  {
    id: "shared-music",
    label: "Shared music",
    category: "music",
    scope: "shared",
    available: true,
  },
  {
    id: "personal-audiobooks",
    label: "My audiobooks",
    category: "audiobooks",
    scope: "personal",
    available: true,
  },
];

function playerFetch() {
  return vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.endsWith("/status"))
      return new Response(
        wireJson({ mutationMode: "enabled", integrations: [] }),
      );
    if (path.endsWith("/session"))
      return new Response(
        wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
      );
    if (path.endsWith("/roots")) return new Response(wireJson(roots));
    if (path.includes("/items?rootId=personal-music"))
      return new Response(wireJson({ items: personalMusic, nextCursor: null }));
    if (path.includes("/items?rootId=shared-music"))
      return new Response(wireJson({ items: sharedMusic, nextCursor: null }));
    if (path.includes("/items?rootId=personal-audiobooks"))
      return new Response(wireJson({ items: audiobooks, nextCursor: null }));
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

const shuffleButton = (root: ParentNode): HTMLButtonElement | undefined =>
  Array.from(
    root.querySelectorAll<HTMLButtonElement>(".player-controls button"),
  ).find((button) => button.getAttribute("aria-label")?.startsWith("Shuffle"));

describe("music player playback options", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("cycles the shuffle button through album, all and off", async () => {
    vi.stubGlobal("fetch", playerFetch());

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="player" />);

    await vi.waitFor(() => expect(shuffleButton(screen)).toBeDefined());
    const shuffle = shuffleButton(screen);
    if (!shuffle) return;

    expect(shuffle.getAttribute("aria-label")).toBe("Shuffle off");
    await userEvent(shuffle, "click");
    await vi.waitFor(() =>
      expect(shuffle.getAttribute("aria-label")).toBe("Shuffle album"),
    );
    await userEvent(shuffle, "click");
    await vi.waitFor(() =>
      expect(shuffleButton(screen)?.getAttribute("aria-label")).toBe(
        "Shuffle all music files",
      ),
    );
    await userEvent(shuffle, "click");
    await vi.waitFor(() =>
      expect(shuffleButton(screen)?.getAttribute("aria-label")).toBe(
        "Shuffle off",
      ),
    );
  });

  it("lists every playback option with its wording", async () => {
    vi.stubGlobal("fetch", playerFetch());

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="player" />);

    await vi.waitFor(() =>
      expect(screen.querySelector(".player-controls")).toBeDefined(),
    );
    const gear = screen.querySelector<HTMLButtonElement>(
      "button[aria-label='Playback options']",
    );
    expect(gear, "playback options button").toBeDefined();
    await userEvent(gear ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".playback-settings")).toBeDefined(),
    );
    const panel = screen.querySelector(".playback-settings")?.textContent ?? "";
    expect(panel).toContain("Shuffle off");
    expect(panel).toContain("Shuffle album");
    expect(panel).toContain("Shuffle all music files");
    expect(panel).toContain("Stop after this track");
    expect(panel).toContain("Continue to the next track");
    expect(panel).toContain("Repeat this track");
    expect(panel).toContain("Repeat the queue");
    expect(panel).toContain("Sleep timer");
  });

  it("marks the stop-after-track option in both the button and the panel", async () => {
    vi.stubGlobal("fetch", playerFetch());

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="player" />);

    await vi.waitFor(() =>
      expect(screen.querySelector(".player-controls")).toBeDefined(),
    );
    const stop = screen.querySelector<HTMLButtonElement>(
      "button[aria-label='Stop after this track']",
    );
    expect(stop?.getAttribute("aria-pressed")).toBe("false");
    await userEvent(stop ?? null, "click");

    await vi.waitFor(() =>
      expect(
        screen
          .querySelector("button[aria-label='Stop after this track']")
          ?.getAttribute("aria-pressed"),
      ).toBe("true"),
    );

    const gear = screen.querySelector<HTMLButtonElement>(
      "button[aria-label='Playback options']",
    );
    await userEvent(gear ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".playback-settings")).toBeDefined(),
    );
    const checked = Array.from(
      screen.querySelectorAll<HTMLButtonElement>(
        "[role='menuitemradio'][aria-checked='true']",
      ),
    ).map((option) => option.textContent ?? "");
    expect(checked).toHaveLength(2);
    expect(checked.join(" ")).toContain("Stop after this track");
  });

  it("names the album and file-type pools of the current track", async () => {
    vi.stubGlobal("fetch", playerFetch());

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="player" />);

    await vi.waitFor(() => expect(screen.textContent).toContain("First Light"));
    const gear = screen.querySelector<HTMLButtonElement>(
      "button[aria-label='Playback options']",
    );
    await userEvent(gear ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".playback-settings")).toBeDefined(),
    );
    const panel = screen.querySelector(".playback-settings")?.textContent ?? "";
    // The album scope names the current album; the file-type scope counts every
    // music track across the personal and shared roots, never the audiobook.
    expect(panel).toContain("Random order inside Blue Hour (2 tracks).");
    expect(panel).toContain("Random order across all 3 tracks");
  });
});
