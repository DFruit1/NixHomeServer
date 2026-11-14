import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";

const refreshCalls = (mock: ReturnType<typeof vi.fn>) =>
  mock.mock.calls.filter(([input]) =>
    String(input).includes("/catalog/refresh"),
  );

const videoRoots = [
  {
    id: "personal-videos",
    label: "My videos",
    category: "videos",
    scope: "personal",
    available: true,
  },
];

const sibling = {
  id: "other-1",
  rootId: "personal-videos",
  relativePath: "Alpha/Other.mkv",
  mediaKind: "video",
  sizeBytes: 1024,
};

const clip = {
  id: "clip-1",
  rootId: "personal-videos",
  relativePath: "Channel/Clip.mkv",
  mediaKind: "video",
  sizeBytes: 2048,
};

const videoScanResult = {
  rootId: "personal-videos",
  result: {
    filesSeen: 2,
    itemsIndexed: 2,
    itemsChanged: 1,
    itemsRemoved: 0,
    entriesSkipped: 0,
    skippedPaths: [],
  },
  requestId: "scan-2",
};

function videoDeepLinkFetch(catalogued: () => boolean, onRefresh?: () => void) {
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
    if (path.endsWith("/roots")) return new Response(wireJson(videoRoots));
    if (path.endsWith("/catalog/refresh")) {
      onRefresh?.();
      return new Response(wireJson(videoScanResult));
    }
    if (path.includes("/items?rootId=personal-videos"))
      return new Response(
        wireJson({
          items: catalogued() ? [clip, sibling] : [sibling],
          nextCursor: null,
        }),
      );
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

describe("downloader deep links into the video player", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("refreshes the hinted root and selects the linked video", async () => {
    let catalogued = false;
    const fetch = videoDeepLinkFetch(
      () => catalogued,
      () => {
        catalogued = true;
      },
    );
    vi.stubGlobal("fetch", fetch);
    const { render, screen, userEvent } = await createDOM();
    await render(
      <Root
        initialView="videos"
        initialRootId="personal-videos"
        initialPath="Channel/Clip.mkv"
      />,
    );
    await vi.waitFor(() => expect(refreshCalls(fetch)).toHaveLength(1));
    expect(JSON.parse(String(refreshCalls(fetch)[0]![1]?.body))).toEqual({
      rootId: "personal-videos",
    });
    // Wait for the post-scan catalog reload to settle before flushing its
    // render; the test DOM has no animation frames, so a user event flushes it.
    const catalogCalls = () =>
      fetch.mock.calls.filter(([input]) =>
        String(input).includes("/items?rootId=personal-videos"),
      ).length;
    await vi.waitFor(() => expect(catalogCalls()).toBe(2));
    // The test DOM has no animation frames, so each poll dispatches a harmless
    // toggle to flush queued task/state renders, then checks the selection.
    // Polling avoids depending on when chooseVideo's async call lands.
    await vi.waitFor(async () => {
      const theatre = screen.querySelector('button[aria-label="Theatre mode"]');
      await userEvent(theatre ?? null, "click");
      expect(screen.querySelector("li.active")?.textContent).toContain("Clip");
    });
  });

  it("does not rescan when the linked video is already catalogued", async () => {
    const fetch = videoDeepLinkFetch(() => true);
    vi.stubGlobal("fetch", fetch);
    const { render } = await createDOM();
    await render(
      <Root
        initialView="videos"
        initialRootId="personal-videos"
        initialPath="Channel/Clip.mkv"
      />,
    );
    await vi.waitFor(() => expect(fetch).toHaveBeenCalled());
    expect(refreshCalls(fetch)).toHaveLength(0);
  });
});
