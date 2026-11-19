import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VideosView, inVideoCategory, videoInfo } from "./videos-view";

const videoRoots = [
  {
    id: "personal-videos",
    label: "My videos",
    category: "videos",
    scope: "personal" as const,
    available: true,
  },
];

const catalog = [
  {
    id: "home-video",
    rootId: "personal-videos",
    relativePath: "Home/Trip.mkv",
    mediaKind: "video",
    sizeBytes: 1024,
    modifiedNs: 1,
    fingerprint: "home",
  },
  {
    id: "youtube-video",
    rootId: "personal-videos",
    relativePath: "_YouTube/Clip.mkv",
    mediaKind: "video",
    sizeBytes: 1024,
    modifiedNs: 1,
    fingerprint: "youtube",
  },
  {
    id: "movie-video",
    rootId: "personal-videos",
    relativePath: "_Movies/Arrival (2016).mkv",
    mediaKind: "video",
    sizeBytes: 1024,
    modifiedNs: 1,
    fingerprint: "movie",
  },
  {
    id: "episode-video",
    rootId: "personal-videos",
    relativePath: "_Shows/Show/Season 1/Show S01E01.mkv",
    mediaKind: "video",
    sizeBytes: 1024,
    modifiedNs: 1,
    fingerprint: "episode",
  },
];

const immichVideo = {
  id: "60000000-0000-4000-8000-000000000001",
  filename: "Beach day.mp4",
  capturedAt: "2026-10-01T10:00:00Z",
};

function fetchFixture() {
  return vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.includes("/provider-lookups/immich/videos?page=1"))
      return new Response(
        wireJson({
          items: [immichVideo],
          nextPage: null,
          requestId: "videos-1",
        }),
      );
    if (path.includes("/items?rootId=personal-videos"))
      return new Response(wireJson({ items: catalog, nextCursor: null }));
    if (path.includes("/metadata"))
      return new Response(wireJson({ title: "" }));
    if (path.includes("/transcript"))
      return new Response(wireJson({ cues: [], requestId: "transcript-1" }));
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

const rowTitles = (screen: HTMLElement) =>
  Array.from(screen.querySelectorAll(".video-list-copy strong")).map(
    (node) => node.textContent,
  );

const categorySelect = (screen: HTMLElement) =>
  screen.querySelector<HTMLSelectElement>(".video-category-select select");

describe("video categories", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("keeps Jellyfin films and episodes out of the default Videos list", () => {
    expect(videoInfo("Home/Trip.mkv").category).toBe("videos");
    expect(videoInfo("_YouTube/Clip.mkv").category).toBe("youtube");
    expect(videoInfo("_Movies/Arrival (2016).mkv").category).toBe("movies");
    expect(videoInfo("_Shows/Show/Season 1/Show S01E01.mkv").category).toBe(
      "shows",
    );
    expect(videoInfo("Discs/VTS_01_1.mkv").category).toBe("dvds");
    // YouTube downloads never reach Jellyfin, so the default keeps them.
    expect(inVideoCategory(videoInfo("_YouTube/Clip.mkv"), "videos")).toBe(
      true,
    );
    expect(
      inVideoCategory(videoInfo("_Movies/Arrival (2016).mkv"), "videos"),
    ).toBe(false);
  });

  it("defaults to Videos and keeps Movies and TV shows one choice away", async () => {
    vi.stubGlobal("fetch", fetchFixture());
    const { render, screen, userEvent } = await createDOM();
    await render(<VideosView roots={videoRoots} />);
    await vi.waitFor(() => expect(categorySelect(screen)).toBeTruthy());
    expect(categorySelect(screen)?.getAttribute("value")).toBe("videos");
    await vi.waitFor(() => expect(rowTitles(screen)).toContain("Trip"));
    expect(
      screen
        .querySelector('a[aria-label="Edit this video"]')
        ?.getAttribute("href"),
    ).toBe("?view=video-editing&item=youtube-video");
    expect(rowTitles(screen)).toContain("Clip");
    expect(rowTitles(screen)).not.toContain("Arrival (2016)");
    expect(rowTitles(screen)).not.toContain("Episode 1");

    const select = categorySelect(screen);
    if (!select) throw new Error("missing category select");
    select.value = "movies";
    await userEvent(select, "change");
    await vi.waitFor(() =>
      expect(rowTitles(screen)).toEqual(["Arrival (2016)"]),
    );
    // The selector already says Movies, so the group heading is redundant.
    expect(screen.querySelector(".video-list-group h3")).toBeFalsy();

    const shows = categorySelect(screen);
    if (!shows) throw new Error("missing category select");
    shows.value = "shows";
    await userEvent(shows, "change");
    await vi.waitFor(() => expect(rowTitles(screen)).toEqual(["Episode 1"]));
    expect(screen.querySelector(".video-list-group h3")?.textContent).toBe(
      "Show",
    );
  });

  it("lists Photos videos and plays them through the server", async () => {
    vi.stubGlobal("fetch", fetchFixture());
    const { render, screen, userEvent } = await createDOM();
    await render(
      <VideosView roots={videoRoots} immichUrl="https://photos.test/" />,
    );
    await vi.waitFor(() => expect(categorySelect(screen)).toBeTruthy());
    expect(
      Array.from(screen.querySelectorAll(".video-category-select option")).map(
        (option) => option.getAttribute("value"),
      ),
    ).toContain("immich");

    const select = categorySelect(screen);
    if (!select) throw new Error("missing category select");
    select.value = "immich";
    await userEvent(select, "change");
    await vi.waitFor(() => expect(rowTitles(screen)).toContain("Beach day"));
    const row = Array.from(screen.querySelectorAll(".video-list-copy strong"))
      .find((node) => node.textContent === "Beach day")
      ?.closest("button");
    await userEvent(row ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.querySelector("video")?.getAttribute("src")).toBe(
        `/api/v1/provider-lookups/immich/videos/${immichVideo.id}/playback`,
      ),
    );
    expect(screen.querySelector("video")?.getAttribute("aria-label")).toBe(
      "Beach day.mp4",
    );
  });
});
