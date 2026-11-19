import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VideoEditingView } from "./video-editing-view";

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

const conversionList = {
  available: true,
  canConvert: true,
  formats: [],
  candidates: [],
  selected: null,
  jobs: [],
  probePending: 0,
  truncated: false,
};

function editingFetch(
  copyRequests: Array<{ body: unknown }>,
  clipRequests: Array<{ body: unknown }>,
) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = String(input);
    if (path.endsWith("/roots")) return new Response(wireJson(videoRoots));
    if (path.endsWith("/items/video-1")) return new Response(wireJson(video));
    if (path.includes("/items?rootId=personal-videos"))
      return new Response(wireJson({ items: [video], nextCursor: null }));
    if (path.endsWith("/conversions/jobs") && init?.method === "POST")
      return new Response(
        wireJson({
          job: {
            id: "conversion-input-1",
            name: "Holiday/Beach.mkv",
            kind: "transcription",
            state: "queued",
            createdAt: 1,
            error: null,
            savedPath: null,
            transcriptId: null,
          },
        }),
      );
    if (path.endsWith("/conversions/jobs"))
      return new Response(
        wireJson({
          jobs: [],
          roots: [
            {
              id: "personal-videos",
              label: "My videos",
              path: "/srv/users/editor/_Videos",
              category: "videos",
            },
          ],
          canSubmit: true,
          maxUploadBytes: 68_719_476_736,
        }),
      );
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
    if (path.endsWith("/video-conversions") && init?.method === "POST") {
      copyRequests.push({ body: JSON.parse(String(init.body ?? "{}")) });
      return new Response(
        wireJson({
          jobs: [
            {
              id: "conversion-1",
              itemId: video.id,
              rootId: video.rootId,
              rootLabel: "My videos",
              relativePath: video.relativePath,
              format: "compatible-mp4",
              mode: "copy",
              state: "queued",
              createdAt: 1,
              sourceBytes: video.sizeBytes,
              archivedPath: null,
              droppedSubtitles: 0,
            },
          ],
          skipped: [],
        }),
        { status: 202 },
      );
    }
    if (path.includes("/video-conversions") && init?.method !== "POST")
      return new Response(wireJson(conversionList));
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
    if (path.includes("/subtitles"))
      return new Response(
        wireJson({
          itemId: video.id,
          subtitles: [],
          consumers: [],
          requestId: "subtitles-1",
        }),
      );
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

describe("video editing", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("queues a trimmed copy and never asks to replace the original", async () => {
    const copyRequests: Array<{ body: unknown }> = [];
    const clipRequests: Array<{ body: unknown }> = [];
    vi.stubGlobal("fetch", editingFetch(copyRequests, clipRequests));
    const { render, screen, userEvent } = await createDOM();
    await render(
      <VideoEditingView
        roots={videoRoots}
        initialItemId={video.id}
        session={{ username: "editor", groups: ["users"], canEdit: true }}
      />,
    );
    await vi.waitFor(() =>
      expect(screen.querySelector("#save-copy-heading")).toBeTruthy(),
    );
    const numbers = Array.from(
      screen.querySelectorAll<HTMLInputElement>('input[type="number"]'),
    );
    numbers[0]!.value = "5";
    await userEvent(numbers[0]!, "input");
    numbers[1]!.value = "12";
    await userEvent(numbers[1]!, "input");
    const save = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Save a copy",
    );
    await userEvent(save ?? null, "click");
    await vi.waitFor(() => expect(copyRequests).toHaveLength(1));
    expect(copyRequests[0]?.body).toEqual({
      itemIds: [video.id],
      format: "compatible-mp4",
      mode: "copy",
      outputName: "Beach (edited).mp4",
      trimStartSeconds: 5,
      trimEndSeconds: 12,
    });
    await vi.waitFor(() =>
      expect(screen.textContent).toContain(
        "Saving Beach (edited).mp4 beside the original.",
      ),
    );
  });

  it("creates a GIF from the selected video", async () => {
    const copyRequests: Array<{ body: unknown }> = [];
    const clipRequests: Array<{ body: unknown }> = [];
    vi.stubGlobal("fetch", editingFetch(copyRequests, clipRequests));
    const { render, screen, userEvent } = await createDOM();
    await render(
      <VideoEditingView
        roots={videoRoots}
        immichUrl="https://photos.test/"
        initialItemId={video.id}
        session={{ username: "editor", groups: ["users"], canEdit: true }}
      />,
    );
    await vi.waitFor(() =>
      expect(screen.querySelector("#create-gif-heading")).toBeTruthy(),
    );
    const length = Array.from(
      screen.querySelectorAll<HTMLInputElement>('input[type="number"]'),
    ).find((input) => input.closest("label")?.textContent?.includes("Length"));
    if (length) length.value = "3";
    await userEvent(length ?? null, "input");
    const create = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create GIF",
    );
    await userEvent(create ?? null, "click");
    await vi.waitFor(() => expect(clipRequests).toHaveLength(1));
    expect(clipRequests[0]?.body).toEqual({
      startSeconds: 0,
      durationSeconds: 3,
      albumId: null,
      albumName: "GIF",
    });
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("GIF saved to GIF."),
    );
  });
});
