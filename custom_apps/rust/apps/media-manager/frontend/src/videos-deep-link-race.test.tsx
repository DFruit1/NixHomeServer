import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { component$, useSignal } from "@builder.io/qwik";
import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VideosView } from "./videos-view";

const videoRoots = [
  {
    id: "personal-videos",
    label: "My videos",
    category: "videos",
    scope: "personal" as const,
    available: true,
  },
];

const other = {
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

const scanResult = {
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

// The harness moves the route to a second download link while the first
// link's rescan is still pending. The flush button stands in for the missing
// animation frames in the test DOM, which is what renders a queued signal
// write.
const Harness = component$(() => {
  const path = useSignal("Alpha/Other.mkv");
  const frame = useSignal(0);
  return (
    <>
      <button
        type="button"
        aria-label="open newer link"
        onClick$={() => (path.value = "Channel/Clip.mkv")}
      >
        newer
      </button>
      <button
        type="button"
        aria-label="flush"
        onClick$={() => (frame.value += 1)}
      >
        flush
      </button>
      <p data-testid="current-path">{path.value}</p>
      <VideosView roots={videoRoots} initialPath={path.value} />
    </>
  );
});

describe("overlapping video deep links", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("keeps the newer link when the older rescan finishes last", async () => {
    const catalogued = new Set<string>();
    const pendingRefresh: Array<() => void> = [];
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.endsWith("/catalog/refresh")) {
        await new Promise<void>((resolve) => pendingRefresh.push(resolve));
        return new Response(wireJson(scanResult));
      }
      if (path.includes("/items?rootId=personal-videos"))
        return new Response(
          wireJson({
            items: [
              ...(catalogued.has("other") ? [other] : []),
              ...(catalogued.has("clip") ? [clip] : []),
            ],
            nextCursor: null,
          }),
        );
      if (path.includes("/metadata"))
        return new Response(wireJson({ title: "" }));
      return new Response(wireJson({ available: false, progress: {} }));
    });
    vi.stubGlobal("fetch", fetch);
    const { render, screen, userEvent } = await createDOM();
    await render(<Harness />);
    const flush = async () =>
      userEvent(
        screen.querySelector('button[aria-label="flush"]') ?? null,
        "click",
      );
    await vi.waitFor(() => expect(pendingRefresh).toHaveLength(1));

    // The route moves on while the first link's rescan is still pending.
    const newer = screen.querySelector('button[aria-label="open newer link"]');
    await userEvent(newer ?? null, "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector('[data-testid="current-path"]')?.textContent,
      ).toBe("Channel/Clip.mkv"),
    );
    await vi.waitFor(() => expect(pendingRefresh).toHaveLength(2));

    // The abandoned link finishes scanning and finds nothing. It must not
    // report that failure for the link the user moved to.
    pendingRefresh[0]!();
    await flush();
    expect(screen.textContent).not.toContain("isn't in the video library");

    // The newer link's own rescan then finds and selects its video.
    catalogued.add("clip");
    pendingRefresh[1]!();
    // The detached scan finishes over several microtasks, so poll with a flush
    // until its selection lands.
    await vi.waitFor(async () => {
      await flush();
      expect(screen.querySelector("li.active")?.textContent).toContain("Clip");
    });
    expect(screen.querySelector("li.active")?.textContent).not.toContain(
      "Other",
    );
    expect(screen.textContent).not.toContain("isn't in the video library");
  });
});
