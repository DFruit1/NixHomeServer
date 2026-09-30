// @vitest-environment node
import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";
import { wireJson } from "./test-support/wire-fixtures";

function item(id: string, relativePath: string) {
  return {
    id,
    rootId: "shared-videos",
    relativePath,
    mediaKind: "video",
    sizeBytes: 1024,
  };
}

function libraryFetch(
  itemsResponse: (url: URL) => Response | Promise<Response>,
  extraRoots: unknown[] = [],
) {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = new URL(String(input), "https://media.example");
    if (url.pathname.endsWith("/items")) return itemsResponse(url);
    if (url.pathname.endsWith("/catalog/refresh"))
      return new Response(
        wireJson({
          rootId: "shared-videos",
          requestId: "refresh-test",
          result: {
            filesSeen: 1,
            itemsIndexed: 1,
            itemsChanged: 0,
            itemsRemoved: 0,
            entriesSkipped: 0,
            skippedPaths: [],
          },
        }),
      );
    const payload = url.pathname.endsWith("/status")
      ? { mutationMode: "enabled", integrations: [] }
      : url.pathname.endsWith("/session")
        ? { username: "dsaw", groups: ["users"], canEdit: false }
        : url.pathname.endsWith("/roots")
          ? [
              {
                id: "shared-videos",
                label: "Shared videos",
                category: "videos",
                scope: "shared",
                available: true,
              },
              ...extraRoots,
            ]
          : { available: false, progress: {} };
    return new Response(wireJson(payload));
  });
}

describe("Media Manager library pagination", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("counts only the returned search page when the retained selection also matches", async () => {
    const baseFetch = libraryFetch(
      (url) =>
        new Response(
          wireJson(
            url.searchParams.has("search")
              ? {
                  items: [item("match", "Contact Movie.mkv")],
                  nextCursor: "Contact Movie.mkv",
                }
              : {
                  items: [item("selected", "Arrival Movie.mkv")],
                  nextCursor: null,
                },
          ),
        ),
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) =>
        String(input).endsWith("/items/selected/metadata")
          ? new Response(
              wireJson({
                mediaType: "movie",
                title: "Arrival",
                language: "en",
                sources: ["filename"],
              }),
            )
          : baseFetch(input),
      ),
    );
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    const filter = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    )!;
    filter.value = "movie";
    await userEvent(filter, "input");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Contact Movie.mkv"),
    );
    expect(screen.querySelector(".library-detail-pane")).toBeDefined();
    expect(screen.querySelector(".library-filter-summary")?.textContent).toBe(
      "1 match",
    );
    expect(screen.querySelectorAll(".shared-pane .tree-row.file")).toHaveLength(
      1,
    );
  });

  it("preserves the selected item's unsaved draft while searching for another item", async () => {
    const selected = item("selected", "Arrival.mkv");
    const baseFetch = libraryFetch(
      (url) =>
        new Response(
          wireJson(
            url.searchParams.has("search")
              ? { items: [item("match", "Contact.mkv")], nextCursor: null }
              : { items: [selected], nextCursor: "Arrival.mkv" },
          ),
        ),
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path.endsWith("/session"))
          return new Response(
            wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
          );
        if (path.endsWith("/items/selected/metadata"))
          return new Response(
            wireJson({
              mediaType: "movie",
              title: "Arrival",
              language: "en",
              sources: ["filename"],
            }),
          );
        return baseFetch(input);
      }),
    );
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    const titleSelector = ".editor-metadata-form .title-input input";
    await vi.waitFor(() =>
      expect(screen.querySelector<HTMLInputElement>(titleSelector)?.value).toBe(
        "Arrival",
      ),
    );
    await userEvent(
      Array.from(screen.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Create draft",
      ) ?? null,
      "click",
    );
    const draftTitle = screen.querySelector<HTMLInputElement>(titleSelector)!;
    draftTitle.value = "Arrival Director's Cut";
    await userEvent(draftTitle, "input");
    const filter = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    )!;
    filter.value = "contact";
    await userEvent(filter, "input");
    await vi.waitFor(() => expect(screen.textContent).toContain("Contact.mkv"));
    expect(screen.querySelector(".library-detail-pane")).toBeDefined();
    expect(screen.querySelector<HTMLInputElement>(titleSelector)?.value).toBe(
      "Arrival Director's Cut",
    );
    expect(draftTitle.isConnected).toBe(true);
    expect(screen.textContent).toContain("1 match");
    expect(screen.querySelectorAll(".shared-pane .tree-row.file")).toHaveLength(
      1,
    );
    expect(
      screen.querySelector(".shared-pane .tree-row.file")?.textContent,
    ).toContain("Contact.mkv");
    expect(
      Array.from(screen.querySelectorAll("button")).some(
        (button) => button.textContent?.trim() === "Load more",
      ),
    ).toBe(false);
    filter.value = "";
    await userEvent(filter, "input");
    await vi.waitFor(() =>
      expect(
        screen.querySelector(".shared-pane .tree-row.file")?.textContent,
      ).toContain("Arrival.mkv"),
    );
    expect(screen.querySelector<HTMLInputElement>(titleSelector)?.value).toBe(
      "Arrival Director's Cut",
    );
    expect(draftTitle.isConnected).toBe(true);
  });

  it("keeps the active search when refreshing the library", async () => {
    const fetchMock = libraryFetch(
      (url) =>
        new Response(
          wireJson(
            url.searchParams.get("search")
              ? { items: [item("match", "Étoile.mkv")], nextCursor: null }
              : {
                  items: [item("first", "First.mkv")],
                  nextCursor: "First.mkv",
                },
          ),
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const input = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    )!;
    input.value = "étoile";
    await userEvent(input, "input");
    await vi.waitFor(() => expect(screen.textContent).toContain("Étoile.mkv"));
    const callsBeforeRefresh = fetchMock.mock.calls.length;
    await userEvent(
      screen.querySelector(
        "button[aria-label='Refresh this library from disk now']",
      ),
      "click",
    );
    await vi.waitFor(() =>
      expect(fetchMock.mock.calls.length).toBeGreaterThan(callsBeforeRefresh),
    );
    const refreshedRequests = fetchMock.mock.calls
      .slice(callsBeforeRefresh)
      .map(([request]) => new URL(String(request), "https://media.example"))
      .filter((url) => url.pathname.endsWith("/items"));
    expect(refreshedRequests.at(-1)?.searchParams.get("search")).toBe("étoile");
    expect(screen.textContent).toContain("Étoile.mkv");
  });

  it("opens a durable folder link whose contents are beyond the first page", async () => {
    const fetchMock = libraryFetch(
      (url) =>
        new Response(
          wireJson(
            url.searchParams.has("search") || url.searchParams.has("pathPrefix")
              ? {
                  items: [item("linked", "ZFolder/Linked.mkv")],
                  nextCursor: null,
                }
              : {
                  items: [item("first", "AFolder/First.mkv")],
                  nextCursor: "AFolder/First.mkv",
                },
          ),
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render } = await createDOM();
    await render(
      <Root
        initialView="library"
        initialRootId="shared-videos"
        initialPath="ZFolder"
      />,
    );
    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([request]) => {
          const url = new URL(String(request), "https://media.example");
          return (
            url.pathname.endsWith("/folders/metadata") &&
            url.searchParams.get("rootId") === "shared-videos" &&
            url.searchParams.get("relativePath") === "ZFolder"
          );
        }),
      ).toBe(true),
    );
  });

  it("publishes a completed root without waiting for the other library pane", async () => {
    let resolvePersonal!: (response: Response) => void;
    const personal = new Promise<Response>((resolve) => {
      resolvePersonal = resolve;
    });
    vi.stubGlobal(
      "fetch",
      libraryFetch(
        (url) =>
          url.searchParams.get("rootId") === "personal-videos"
            ? personal
            : new Response(
                wireJson({
                  items: [item("ready", "Ready.mkv")],
                  nextCursor: null,
                }),
              ),
        [
          {
            id: "personal-videos",
            label: "My videos",
            category: "videos",
            scope: "personal",
            available: true,
          },
        ],
      ),
    );
    const { render, screen, userEvent } = await createDOM();
    const rendering = render(
      <Root initialView="library" initialRootId="shared-videos" />,
    );
    try {
      await vi.waitFor(() => expect(screen.textContent).toContain("Ready.mkv"));
    } finally {
      resolvePersonal(new Response(wireJson({ items: [], nextCursor: null })));
      await rendering;
      await vi.waitFor(async () => {
        await userEvent(screen, "click");
        expect(screen.textContent).not.toContain("Loading…");
      });
    }
  });

  it("deduplicates a linked item when its slower root page arrives", async () => {
    let resolvePersonal!: (response: Response) => void;
    const personal = new Promise<Response>((resolve) => {
      resolvePersonal = resolve;
    });
    const linked = {
      ...item("linked", "Linked.mkv"),
      rootId: "personal-videos",
    };
    const baseFetch = libraryFetch(
      (url) =>
        url.searchParams.get("rootId") === "personal-videos"
          ? personal
          : new Response(
              wireJson({
                items: [item("ready", "Ready.mkv")],
                nextCursor: null,
              }),
            ),
      [
        {
          id: "personal-videos",
          label: "My videos",
          category: "videos",
          scope: "personal",
          available: true,
        },
      ],
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) =>
        String(input).endsWith("/items/linked")
          ? new Response(wireJson(linked))
          : baseFetch(input),
      ),
    );
    const { render, screen, userEvent } = await createDOM();
    const rendering = render(
      <Root
        initialView="library"
        initialRootId="personal-videos"
        initialItemId="linked"
      />,
    );
    try {
      await rendering;
      expect(
        screen.querySelectorAll(".personal-pane .tree-row.file"),
      ).toHaveLength(1);
      resolvePersonal(
        new Response(wireJson({ items: [linked], nextCursor: null })),
      );
      await vi.waitFor(async () => {
        await userEvent(screen, "click");
        expect(screen.textContent).not.toContain("Loading…");
      });
      expect(
        screen.querySelectorAll(".personal-pane .tree-row.file"),
      ).toHaveLength(1);
    } finally {
      resolvePersonal(new Response(wireJson({ items: [], nextCursor: null })));
      await rendering;
      await vi.waitFor(async () => {
        await userEvent(screen, "click");
        expect(screen.textContent).not.toContain("Loading…");
      });
    }
  });

  it("discards an older search that completes after the current search", async () => {
    let resolveOlder!: (response: Response) => void;
    const older = new Promise<Response>((resolve) => {
      resolveOlder = resolve;
    });
    const fetchMock = libraryFetch((url) =>
      url.searchParams.get("search") === "old"
        ? older
        : new Response(
            wireJson({ items: [item("new", "New.mkv")], nextCursor: null }),
          ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const input = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    )!;
    input.value = "old";
    const oldInput = userEvent(input, "input");
    try {
      await vi.waitFor(() =>
        expect(
          fetchMock.mock.calls.some(([request]) =>
            String(request).includes("search=old"),
          ),
        ).toBe(true),
      );
      input.value = "new";
      await userEvent(input, "input");
      await vi.waitFor(() => expect(screen.textContent).toContain("New.mkv"));
      resolveOlder(
        new Response(
          wireJson({ items: [item("old", "Old.mkv")], nextCursor: "Old.mkv" }),
        ),
      );
      await oldInput;
      expect(screen.textContent).toContain("New.mkv");
      expect(screen.textContent).not.toContain("Old.mkv");
      expect(
        Array.from(screen.querySelectorAll("button")).some(
          (button) => button.textContent?.trim() === "Load more",
        ),
      ).toBe(false);
    } finally {
      resolveOlder(new Response(wireJson({ items: [], nextCursor: null })));
      await oldInput;
    }
  });

  it("discards a pending video search after switching to music", async () => {
    let resolveVideos!: (response: Response) => void;
    const videos = new Promise<Response>((resolve) => {
      resolveVideos = resolve;
    });
    const fetchMock = libraryFetch(
      (url) =>
        url.searchParams.get("search") === "pending"
          ? videos
          : new Response(
              wireJson({
                items:
                  url.searchParams.get("rootId") === "shared-music"
                    ? [
                        {
                          ...item("music", "Track.mp3"),
                          rootId: "shared-music",
                          mediaKind: "music",
                        },
                      ]
                    : [item("video", "Video.mkv")],
                nextCursor: null,
              }),
            ),
      [
        {
          id: "shared-music",
          label: "Music",
          category: "music",
          scope: "shared",
          available: true,
        },
      ],
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const input = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    )!;
    input.value = "pending";
    const pending = userEvent(input, "input");
    try {
      await vi.waitFor(() =>
        expect(
          fetchMock.mock.calls.some(([request]) =>
            String(request).includes("search=pending"),
          ),
        ).toBe(true),
      );
      await userEvent(
        Array.from(screen.querySelectorAll(".library-tab")).find(
          (tab) => tab.textContent?.trim() === "Music",
        ) ?? null,
        "click",
      );
      await vi.waitFor(() => expect(screen.textContent).toContain("Track.mp3"));
      resolveVideos(
        new Response(
          wireJson({
            items: [item("stale", "Stale.mkv")],
            nextCursor: "Stale.mkv",
          }),
        ),
      );
      await pending;
      expect(screen.textContent).toContain("Track.mp3");
      expect(screen.textContent).not.toContain("Stale.mkv");
      expect(input.value).toBe("");
    } finally {
      resolveVideos(new Response(wireJson({ items: [], nextCursor: null })));
      await pending;
    }
  });

  it("shows the initial page before requesting more and keeps it visible while more loads", async () => {
    let resolveNext!: (response: Response) => void;
    const next = new Promise<Response>((resolve) => {
      resolveNext = resolve;
    });
    const fetchMock = libraryFetch((url) =>
      url.searchParams.has("cursor")
        ? next
        : new Response(
            wireJson({
              items: [item("first", "First.mkv")],
              nextCursor: "First.mkv",
            }),
          ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    const rendering = render(
      <Root initialView="library" initialRootId="shared-videos" />,
    );
    try {
      await vi.waitFor(() => expect(screen.textContent).toContain("First.mkv"));
      expect(
        fetchMock.mock.calls.some(([input]) =>
          String(input).includes("cursor="),
        ),
      ).toBe(false);
      const more = Array.from(screen.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Load more",
      );
      expect(more, "reachable Load more control").toBeDefined();
      const loading = userEvent(more ?? null, "click");
      await vi.waitFor(() =>
        expect(
          fetchMock.mock.calls.some(([input]) =>
            String(input).includes("cursor="),
          ),
        ).toBe(true),
      );
      expect(screen.textContent).toContain("First.mkv");
      resolveNext(
        new Response(
          wireJson({ items: [item("second", "Second.mkv")], nextCursor: null }),
        ),
      );
      await loading;
      await vi.waitFor(() =>
        expect(screen.textContent).toContain("Second.mkv"),
      );
      expect(screen.textContent).toContain("First.mkv");
      expect(
        Array.from(screen.querySelectorAll("button")).some(
          (button) => button.textContent?.trim() === "Load more",
        ),
      ).toBe(false);
    } finally {
      resolveNext(new Response(wireJson({ items: [], nextCursor: null })));
      await rendering;
    }
  });

  it("searches beyond loaded pages and resets pagination when the filter changes", async () => {
    const fetchMock = libraryFetch(
      (url) =>
        new Response(
          wireJson(
            url.searchParams.get("search")
              ? { items: [item("match", "Étoile.mkv")], nextCursor: null }
              : {
                  items: [item("first", "First.mkv")],
                  nextCursor: "First.mkv",
                },
          ),
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const filter = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    );
    expect(filter).toBeDefined();
    if (!filter) return;
    filter.value = "étoile";
    await userEvent(filter, "input");
    await vi.waitFor(() => expect(screen.textContent).toContain("Étoile.mkv"));
    expect(screen.textContent).not.toContain("First.mkv");
    const searchRequests = fetchMock.mock.calls
      .map(([input]) => new URL(String(input), "https://media.example"))
      .filter((url) => url.searchParams.has("search"));
    expect(searchRequests.length).toBeGreaterThan(0);
    expect(searchRequests.at(-1)?.searchParams.get("search")).toBe("étoile");
    expect(searchRequests.at(-1)?.searchParams.has("cursor")).toBe(false);
    filter.value = "";
    await userEvent(filter, "input");
    await vi.waitFor(() => expect(screen.textContent).toContain("First.mkv"));
    expect(screen.textContent).not.toContain("Étoile.mkv");
  });
});
