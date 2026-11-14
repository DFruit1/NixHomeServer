import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";

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
];

const song = {
  id: "song-1",
  rootId: "personal-music",
  relativePath: "_YouTube/Channel One/01 - Song.flac",
  mediaKind: "music",
  sizeBytes: 1024,
};

const scanResult = {
  rootId: "personal-music",
  result: {
    filesSeen: 1,
    itemsIndexed: 1,
    itemsChanged: 1,
    itemsRemoved: 0,
    entriesSkipped: 0,
    skippedPaths: [],
  },
  requestId: "scan-1",
};

function downloaderDeepLinkFetch(
  catalogued: () => boolean,
  onRefresh?: () => void,
) {
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
    if (path.endsWith("/catalog/refresh")) {
      onRefresh?.();
      return new Response(wireJson(scanResult));
    }
    if (path.includes("/items?rootId=personal-music"))
      return new Response(
        wireJson({ items: catalogued() ? [song] : [], nextCursor: null }),
      );
    if (path.includes("/items?rootId=shared-music"))
      return new Response(wireJson({ items: [], nextCursor: null }));
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

const refreshCalls = (mock: ReturnType<typeof vi.fn>) =>
  mock.mock.calls.filter(([input]) =>
    String(input).includes("/catalog/refresh"),
  );
describe("downloader deep links into the music player", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("refreshes the hinted root when the new download is not catalogued yet", async () => {
    let catalogued = false;
    const fetch = downloaderDeepLinkFetch(
      () => catalogued,
      () => {
        catalogued = true;
      },
    );
    vi.stubGlobal("fetch", fetch);
    const { render, screen } = await createDOM();
    await render(
      <Root
        initialView="player"
        initialRootId="personal-music"
        initialPath="Channel One/01 - Song.flac"
      />,
    );
    await vi.waitFor(() =>
      expect(screen.querySelector("audio")?.getAttribute("src")).toBe(
        "/api/v1/items/song-1/stream",
      ),
    );
    expect(refreshCalls(fetch)).toHaveLength(1);
    const [, init] = refreshCalls(fetch)[0]!;
    expect(JSON.parse(String(init?.body))).toEqual({
      rootId: "personal-music",
    });
  });

  it("does not rescan a root for a track that is already catalogued", async () => {
    const fetch = downloaderDeepLinkFetch(() => true);
    vi.stubGlobal("fetch", fetch);
    const { render, screen } = await createDOM();
    await render(
      <Root
        initialView="player"
        initialRootId="personal-music"
        initialPath="Channel One/01 - Song.flac"
      />,
    );
    await vi.waitFor(() =>
      expect(screen.querySelector("audio")?.getAttribute("src")).toBe(
        "/api/v1/items/song-1/stream",
      ),
    );
    expect(refreshCalls(fetch)).toHaveLength(0);
  });

  it("reports a download that stays outside the indexed library", async () => {
    const fetch = downloaderDeepLinkFetch(() => false);
    vi.stubGlobal("fetch", fetch);
    const { render, screen, userEvent } = await createDOM();
    await render(
      <Root
        initialView="player"
        initialRootId="personal-music"
        initialPath="Channel One/01 - Song.wav"
      />,
    );
    await vi.waitFor(() => expect(refreshCalls(fetch)).toHaveLength(1));
    // A visible-task signal write renders on the next frame; the test DOM has
    // no animation frames, so a user event flushes the queued render.
    const search = screen.querySelector(
      'button[aria-label="Search albums and tracks"]',
    );
    await userEvent(search ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain(
        "The linked download isn't in the music library.",
      ),
    );
    expect(refreshCalls(fetch)).toHaveLength(1);
  });

  it("does not apply a deep link after the user starts something else", async () => {
    const otherSong = {
      id: "other-1",
      rootId: "personal-music",
      relativePath: "_YouTube/Other Album/01 - Other.flac",
      mediaKind: "music",
      sizeBytes: 1024,
    };
    const pendingRefresh: { release: (() => void) | null } = {
      release: null,
    };
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
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
      if (path.endsWith("/catalog/refresh")) {
        await new Promise<void>((resolve) => {
          pendingRefresh.release = resolve;
        });
        return new Response(wireJson(scanResult));
      }
      if (path.includes("/items?rootId=personal-music"))
        return new Response(wireJson({ items: [otherSong], nextCursor: null }));
      if (path.includes("/items?rootId=shared-music"))
        return new Response(wireJson({ items: [], nextCursor: null }));
      return new Response(wireJson({ available: false, progress: {} }));
    });
    vi.stubGlobal("fetch", fetch);
    const { render, screen, userEvent } = await createDOM();
    await render(
      <Root
        initialView="player"
        initialRootId="personal-music"
        initialPath="Channel One/01 - Song.flac"
      />,
    );
    await vi.waitFor(() => expect(refreshCalls(fetch)).toHaveLength(1));
    // The user starts the album that is already in the catalog while the
    // rescan is still pending.
    const playAll = screen.querySelector('button[aria-label="Play all music"]');
    await userEvent(playAll ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.querySelector("audio")?.getAttribute("src")).toBe(
        "/api/v1/items/other-1/stream",
      ),
    );
    pendingRefresh.release?.();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(screen.textContent).not.toContain("isn't in the music library");
    expect(screen.querySelector("audio")?.getAttribute("src")).toBe(
      "/api/v1/items/other-1/stream",
    );
  });
});
