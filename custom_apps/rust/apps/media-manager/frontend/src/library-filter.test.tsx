import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";

const items = [
  {
    id: "arrival",
    rootId: "shared-videos",
    relativePath: "Arrival (2016).mkv",
    mediaKind: "video",
    sizeBytes: 1024,
  },
  {
    id: "blade",
    rootId: "shared-videos",
    relativePath: "Blade Runner (1982).mkv",
    mediaKind: "video",
    sizeBytes: 2048,
  },
];

function libraryFetch(integrations: unknown[]) {
  return vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.endsWith("/status"))
      return new Response(wireJson({ mutationMode: "enabled", integrations }));
    if (path.endsWith("/session"))
      return new Response(
        wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
      );
    if (path.endsWith("/roots"))
      return new Response(
        wireJson([
          {
            id: "shared-videos",
            label: "Shared videos",
            category: "videos",
            scope: "shared",
            available: true,
          },
        ]),
      );
    if (path.includes("/items?rootId=shared-videos"))
      return new Response(wireJson({ items, nextCursor: null }));
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

describe("Media Manager in-view library filter", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("filters rendered titles and filenames without a server search", async () => {
    const fetchMock = libraryFetch([]);
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Blade Runner (1982).mkv"),
    );

    const input = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    );
    expect(input, "filter input").toBeDefined();
    if (!input) return;
    input.value = "arrival";
    await userEvent(input, "input");

    await vi.waitFor(() =>
      expect(screen.textContent).not.toContain("Blade Runner (1982).mkv"),
    );
    expect(screen.textContent).toContain("Arrival (2016).mkv");
    expect(screen.textContent).toContain("1 match");
    expect(
      fetchMock.mock.calls.some(([input]) =>
        String(input).includes("/items/search"),
      ),
    ).toBe(false);
  });

  it("links to the Search app when the optional integration is registered", async () => {
    vi.stubGlobal(
      "fetch",
      libraryFetch([
        {
          id: "search",
          label: "Advanced search",
          available: true,
          capabilities: ["advanced-search"],
          url: "https://search.example",
        },
      ]),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    await vi.waitFor(() =>
      expect(screen.querySelector("a.library-advanced-search")).toBeDefined(),
    );
    const link = screen.querySelector<HTMLAnchorElement>(
      "a.library-advanced-search",
    );
    expect(link?.getAttribute("href")).toBe("https://search.example/?q=");

    const input = screen.querySelector<HTMLInputElement>(
      "input[aria-label='Filter titles and filenames in this library']",
    );
    if (!input) return;
    input.value = "dune";
    await userEvent(input, "input");
    await vi.waitFor(() =>
      expect(link?.getAttribute("href")).toBe("https://search.example/?q=dune"),
    );
  });

  it("hides the advanced search link when the integration is absent", async () => {
    vi.stubGlobal("fetch", libraryFetch([]));
    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await vi.waitFor(() =>
      expect(screen.querySelector(".shared-pane")).toBeDefined(),
    );
    expect(screen.querySelector("a.library-advanced-search")).toBeFalsy();
  });

  it("refreshes the library from disk on demand", async () => {
    let refreshes = 0;
    const base = libraryFetch([]);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        if (
          String(input).endsWith("/catalog/refresh") &&
          init?.method === "POST"
        ) {
          refreshes += 1;
          return new Response(
            wireJson({
              rootId: "shared-videos",
              result: {
                filesSeen: 2,
                itemsIndexed: 2,
                itemsChanged: 2,
                itemsRemoved: 0,
                entriesSkipped: 0,
                skippedPaths: [],
              },
              requestId: "req",
            }),
          );
        }
        return base(input);
      }),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Blade Runner (1982).mkv"),
    );

    const refresh = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Refresh",
    );
    expect(refresh, "refresh button").toBeDefined();
    await userEvent(refresh ?? null, "click");
    await vi.waitFor(() => expect(refreshes).toBeGreaterThan(0));
  });
});
