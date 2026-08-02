// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root, {
  initialRouteFromSearch,
  rootFromSearch,
  viewFromSearch,
} from "./root";

describe("Media Manager navigation", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("maps native navigation URLs to dashboard sections", () => {
    expect(viewFromSearch("?view=library")).toBe("library");
    expect(viewFromSearch("?view=conversions")).toBe("conversions");
    expect(viewFromSearch("?view=unknown")).toBe("overview");
    expect(rootFromSearch("?view=library&root=shared-videos")).toBe(
      "shared-videos",
    );
    expect(initialRouteFromSearch("?view=library&root=shared-videos")).toEqual({
      initialView: "library",
      initialRootId: "shared-videos",
    });
  });

  it("exposes every dashboard section as a native link", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? { mutationMode: "enabled", integrations: [] }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? [
                  {
                    id: "shared-videos",
                    label: "Shared videos",
                    category: "videos",
                    scope: "shared",
                    available: true,
                  },
                ]
              : { available: false, progress: {} };
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root />);

    const expectedLinks = new Map([
      ["Overview", "?view=overview"],
      ["Libraries", "?view=library"],
      ["Conversions", "?view=conversions"],
      ["Subtitles", "?view=subtitles"],
      ["Metadata", "?view=metadata"],
      ["App refresh", "?view=refresh"],
    ]);

    for (const [label, href] of expectedLinks) {
      const link = Array.from(screen.querySelectorAll("a.nav-item")).find(
        (element) => element.textContent?.trim() === label,
      );
      expect(link, `${label} navigation link`).toBeDefined();
      expect(link?.getAttribute("href")).toBe(href);
    }

    const browseLink = Array.from(screen.querySelectorAll("a")).find(
      (element) => element.textContent?.trim() === "Browse libraries",
    );
    expect(browseLink?.getAttribute("href")).toBe("?view=library");
    expect(screen.querySelector("a.root-row")?.getAttribute("href")).toBe(
      "?view=library&root=shared-videos",
    );
  });

  it("renders a section selected by the current URL", async () => {
    const { render, screen } = await createDOM();
    await render(<Root initialView="metadata" />);

    expect(screen.querySelector("h1")?.textContent).toBe("Metadata");
  });

  it("loads a media root selected by a native root-row URL", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      const payload = path.endsWith("/status")
        ? { mutationMode: "enabled", integrations: [] }
        : path.endsWith("/session")
          ? { username: "dsaw", groups: ["users"], canEdit: false }
          : path.endsWith("/roots")
            ? [
                {
                  id: "shared-videos",
                  label: "Shared videos",
                  category: "videos",
                  scope: "shared",
                  available: true,
                },
              ]
            : path.includes("/items?rootId=shared-videos")
              ? { items: [] }
              : { available: false, progress: {} };
      return new Response(JSON.stringify(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    expect(screen.querySelector("h1")?.textContent).toBe("Libraries");
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/items?rootId=shared-videos",
      expect.objectContaining({ credentials: "same-origin" }),
    );
  });
});
