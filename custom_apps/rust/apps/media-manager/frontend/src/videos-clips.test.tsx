import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

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

const video = {
  id: "video-1",
  rootId: "personal-videos",
  relativePath: "Holiday/Beach.mkv",
  mediaKind: "video",
  sizeBytes: 2048,
  modifiedNs: 1,
  fingerprint: "fixture",
};

const albumId = "30000000-0000-4000-8000-000000000001";

describe("video GIF export", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("defaults to a new GIF album and posts the captured position", async () => {
    const clipRequests: Array<{ body: unknown }> = [];
    const fetch = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path.endsWith("/provider-lookups/immich/albums"))
          return new Response(
            wireJson({
              albums: [
                { id: albumId, name: "Trips", assetCount: 4 },
                {
                  id: "30000000-0000-4000-8000-000000000002",
                  name: "Family",
                  assetCount: 2,
                },
              ],
              requestId: "albums-1",
            }),
          );
        if (path.includes("/items?rootId=personal-videos"))
          return new Response(wireJson({ items: [video], nextCursor: null }));
        if (path.endsWith("/items/video-1/clips")) {
          clipRequests.push({ body: JSON.parse(String(init?.body ?? "{}")) });
          return new Response(
            wireJson({
              assetId: "40000000-0000-4000-8000-000000000001",
              albumId: "50000000-0000-4000-8000-000000000001",
              albumName: "GIF",
              filename: "Beach-42.5s-3s.gif",
              startSeconds: 42.5,
              durationSeconds: 3,
              requestId: "clip-1",
            }),
            { status: 201 },
          );
        }
        if (path.includes("/metadata"))
          return new Response(wireJson({ title: "" }));
        return new Response(wireJson({ available: false, progress: {} }));
      },
    );
    vi.stubGlobal("fetch", fetch);
    const { render, screen, userEvent } = await createDOM();
    await render(
      <VideosView
        roots={videoRoots}
        immichUrl="https://photos.test/"
        initialItemId={video.id}
      />,
    );
    const player = screen.querySelector("video");
    Object.defineProperty(player, "duration", {
      value: 120,
      configurable: true,
    });
    Object.defineProperty(player, "currentTime", {
      value: 42.5,
      configurable: true,
      writable: true,
    });
    await vi.waitFor(() =>
      expect(
        screen.querySelector('button[aria-haspopup="dialog"]'),
      ).toBeTruthy(),
    );
    await userEvent(
      screen.querySelector('button[aria-haspopup="dialog"]') ?? null,
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector('[role="dialog"]')?.textContent).toContain(
        "From 0:42",
      ),
    );
    const dialog = screen.querySelector('[role="dialog"]');
    expect(dialog?.textContent).toContain("GIF (new album)");
    const length = dialog?.querySelector<HTMLInputElement>(
      'input[type="number"]',
    );
    if (length) length.value = "3";
    await userEvent(length ?? null, "input");
    await userEvent(
      dialog?.querySelector('button[type="submit"]') ?? null,
      "submit",
    );
    await vi.waitFor(() => expect(clipRequests).toHaveLength(1));
    expect(clipRequests[0]?.body).toEqual({
      startSeconds: 42.5,
      durationSeconds: 3,
      albumId: null,
      albumName: "GIF",
    });
    await vi.waitFor(() =>
      expect(screen.querySelector(".video-clip-status")?.textContent).toContain(
        "GIF saved to",
      ),
    );
    expect(
      screen.querySelector(".video-clip-status a")?.getAttribute("href"),
    ).toBe("https://photos.test/albums/50000000-0000-4000-8000-000000000001");
  });
});
