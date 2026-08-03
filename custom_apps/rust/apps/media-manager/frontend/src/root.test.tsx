// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root, {
  initialRouteFromSearch,
  refreshPresentation,
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

  it("renders a section selected by the current URL without server or mode banners", async () => {
    const { render, screen } = await createDOM();
    await render(<Root initialView="metadata" />);

    expect(screen.querySelector("h1")?.textContent).toBe("Metadata");
    expect(screen.textContent).not.toContain("Sydney Basiniot Media Server");
    expect(screen.textContent).not.toContain("Staged changes enabled");
    expect(screen.querySelector(".mode-pill")).toBeUndefined();
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

  it("loads the first visible media root when the URL does not select one", async () => {
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
              ? {
                  items: [
                    {
                      id: "item-1",
                      rootId: "shared-videos",
                      relativePath: "Movie.mkv",
                      mediaKind: "video",
                      sizeBytes: 5,
                    },
                  ],
                }
              : { available: false, progress: {} };
      return new Response(JSON.stringify(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" />);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/items?rootId=shared-videos",
      expect.objectContaining({ credentials: "same-origin" }),
    );
    expect(screen.textContent).toContain("Movie.mkv");
  });

  it("exposes every library choice as a native selected-route link", async () => {
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
                  {
                    id: "shared-music",
                    label: "Shared music",
                    category: "music",
                    scope: "shared",
                    available: true,
                  },
                ]
              : path.includes("/items?rootId=shared-videos")
                ? { items: [] }
                : { available: false, progress: {} };
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const choices = Array.from(screen.querySelectorAll("a.root-choice"));
    expect(choices.map((choice) => choice.getAttribute("href"))).toEqual([
      "?view=library&root=shared-videos",
      "?view=library&root=shared-music",
    ]);
    expect(choices[0]?.getAttribute("aria-current")).toBe("true");
    expect(choices[1]?.getAttribute("aria-current")).toBeNull();
  });
});

describe("Media Manager refresh feedback", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("distinguishes queued, running, successful, and failed refresh states", () => {
    expect(
      refreshPresentation({ integrationId: "jellyfin", state: "queued" }),
    ).toMatchObject({ label: "Queued", busy: true, tone: "pending" });
    expect(
      refreshPresentation({ integrationId: "jellyfin", state: "running" }),
    ).toMatchObject({ label: "Refreshing…", busy: true, tone: "pending" });
    expect(
      refreshPresentation({
        integrationId: "jellyfin",
        state: "succeeded",
        message: "Jellyfin library scan completed.",
      }),
    ).toMatchObject({
      label: "Succeeded",
      detail: "Jellyfin library scan completed.",
      busy: false,
      tone: "success",
    });
    expect(
      refreshPresentation({
        integrationId: "jellyfin",
        state: "failed",
        message: "Jellyfin library scan failed.",
      }),
    ).toMatchObject({
      label: "Failed",
      detail: "Jellyfin library scan failed.",
      busy: false,
      tone: "error",
    });
  });

  it("lets an authenticated viewer request a refresh and follows it to completion", async () => {
    let refreshQueued = false;
    let refreshStatusReads = 0;
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (
          path.endsWith("/integrations/jellyfin/refresh") &&
          init?.method !== "POST" &&
          refreshQueued &&
          refreshStatusReads++ === 0
        ) {
          return new Response(
            JSON.stringify({
              error: { code: "temporarily_unavailable", message: "Try again." },
            }),
            { status: 503 },
          );
        }
        const payload = path.endsWith("/status")
          ? {
              mutationMode: "enabled",
              integrations: [
                {
                  id: "jellyfin",
                  label: "Jellyfin",
                  available: true,
                  capabilities: ["library-refresh"],
                },
              ],
            }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? []
              : path.endsWith("/conversions")
                ? { available: false, progress: {} }
                : path.endsWith("/integrations/jellyfin/refresh") &&
                    init?.method === "POST"
                  ? ((refreshQueued = true),
                    {
                      integrationId: "jellyfin",
                      state: "queued",
                      alreadyQueued: false,
                      requestId: "r123-1",
                    })
                  : path.endsWith("/integrations/jellyfin/refresh")
                    ? refreshQueued
                      ? {
                          integrationId: "jellyfin",
                          state: "succeeded",
                          requestId: "r123-1",
                          message: "Jellyfin library scan completed.",
                        }
                      : { integrationId: "jellyfin", state: "idle" }
                    : {};
        return new Response(JSON.stringify(payload));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="refresh" />);
    const refreshButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Refresh",
    );
    expect(refreshButton).toBeDefined();

    await userEvent(refreshButton ?? null, "click");
    expect(screen.textContent).toContain("Succeeded");
    expect(screen.textContent).toContain("Jellyfin library scan completed.");
    expect(refreshStatusReads).toBeGreaterThanOrEqual(2);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/integrations/jellyfin/refresh",
      expect.objectContaining({ method: "POST", credentials: "same-origin" }),
    );
  });

  it("keeps setup-only integrations out of app refresh", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? {
              mutationMode: "enabled",
              integrations: [
                {
                  id: "jellyfin",
                  label: "Jellyfin",
                  available: true,
                  capabilities: ["library-refresh"],
                },
                {
                  id: "mkvmaker",
                  label: "DVD ISO converter",
                  available: false,
                  capabilities: ["conversion-progress"],
                },
                {
                  id: "opensubtitles",
                  label: "OpenSubtitles",
                  available: false,
                  capabilities: ["subtitle-search", "subtitle-download"],
                },
              ],
            }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? []
              : { available: false, progress: {} };
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="refresh" />);

    expect(screen.textContent).toContain("Jellyfin");
    expect(screen.textContent).not.toContain("DVD ISO converter");
    expect(screen.textContent).not.toContain("OpenSubtitles");
    expect(
      Array.from(screen.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Instructions",
      ),
    ).toBeUndefined();
  });
});

describe("Media Manager conversions inbox", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("lists inbox ISOs with identification and shows setup guidance", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? { mutationMode: "enabled", integrations: [] }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? []
              : path.endsWith("/conversions/inbox")
                ? {
                    available: true,
                    pending: [
                      {
                        name: "MOVIE_DISC.ISO",
                        volumeId: "EXAMPLE_MOVIE",
                        sizeBytes: 536870912,
                        modifiedNs: 1754000000000000000,
                      },
                    ],
                    processed: [
                      {
                        name: "OLD_MOVIE.ISO",
                        volumeId: null,
                        sizeBytes: 268435456,
                        modifiedNs: 1753000000000000000,
                      },
                    ],
                    failed: [],
                  }
                : path.endsWith("/conversions")
                  ? { available: true, progress: { conversions: [] } }
                  : {};
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="conversions" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("EXAMPLE_MOVIE"),
    );
    expect(screen.textContent).toContain("MOVIE_DISC.ISO");
    expect(screen.textContent).toContain("512 MiB");
    expect(screen.textContent).toContain("Waiting");
    expect(screen.textContent).toContain("Processed");
    expect(screen.textContent).toContain("Failed");
    expect(screen.textContent).toContain("OLD_MOVIE.ISO");
    expect(screen.textContent).toContain(
      "Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.",
    );
    expect(screen.textContent).toContain("No failed conversions.");
  });
});

describe("Media Manager library browser", () => {
  afterEach(() => vi.unstubAllGlobals());

  function libraryFetchMock(items: unknown[]) {
    return vi.fn(async (input: RequestInfo | URL) => {
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
                {
                  id: "shared-music",
                  label: "Shared music",
                  category: "music",
                  scope: "shared",
                  available: true,
                },
                {
                  id: "personal-videos",
                  label: "My videos",
                  category: "videos",
                  scope: "personal",
                  available: true,
                },
              ]
            : path.includes("/items?rootId=")
              ? { items }
              : { available: false, progress: {} };
      return new Response(JSON.stringify(payload));
    });
  }

  it("groups roots under Shared and Personal headers with short names", async () => {
    vi.stubGlobal("fetch", libraryFetchMock([]));

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const headings = Array.from(
      screen.querySelectorAll(".root-group-heading"),
    ).map((heading) => heading.textContent);
    expect(headings).toEqual(["Shared", "Personal"]);
    const choices = Array.from(
      screen.querySelectorAll("a.root-choice strong"),
    ).map((element) => element.textContent);
    expect(choices).toEqual(["Videos", "Music", "Videos"]);
    expect(screen.textContent).not.toContain("Shared videos");
  });

  it("renders a folder tree with toggle buttons instead of a type column", async () => {
    const items = [
      {
        id: "item-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Example Movie (2020).mkv",
        mediaKind: "video",
        sizeBytes: 1024,
      },
      {
        id: "item-2",
        rootId: "shared-videos",
        relativePath: "_Shows/Example Show/Season 01/Episode.mkv",
        mediaKind: "video",
        sizeBytes: 2048,
      },
    ];
    vi.stubGlobal("fetch", libraryFetchMock(items));

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    expect(screen.querySelector(".table-header")).toBeUndefined();
    expect(screen.querySelector(".kind-pill")).toBeUndefined();
    expect(screen.textContent).toContain("Example Movie (2020).mkv");

    const filterButtons = Array.from(
      screen.querySelectorAll(".folder-filter-button"),
    );
    expect(filterButtons.map((button) => button.textContent)).toEqual([
      "Movies",
      "Shows",
    ]);

    await userEvent(filterButtons[1] ?? null, "click");
    expect(filterButtons[1]?.classList.contains("active")).toBe(true);
    expect(screen.textContent).not.toContain("Example Movie (2020).mkv");
    expect(screen.textContent).toContain("Episode.mkv");

    await userEvent(filterButtons[1] ?? null, "click");
    expect(screen.textContent).toContain("Example Movie (2020).mkv");
  });
});

describe("Media Manager visual hierarchy", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("omits tiny section labels and the redundant overview statistics", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? { mutationMode: "enabled", integrations: [] }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? []
              : { available: false, progress: {} };
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="overview" />);

    expect(screen.querySelector(".section-label")).toBeUndefined();
    expect(screen.querySelector(".stat-grid")).toBeUndefined();
    expect(screen.textContent).not.toContain("Available roots");
    expect(screen.textContent).not.toContain("Active conversions");
    expect(screen.textContent).not.toContain("Connected apps");
  });
});
