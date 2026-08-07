// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root, {
  initialRouteFromSearch,
  parseTvEpisodeFilename,
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
      ["App refresh", "?view=refresh"],
    ]);

    for (const [label, href] of expectedLinks) {
      const link = Array.from(screen.querySelectorAll("a.nav-item")).find(
        (element) => element.textContent?.trim() === label,
      );
      expect(link, `${label} navigation link`).toBeDefined();
      expect(link?.getAttribute("href")).toBe(href);
    }
  });

  it("renders a section selected by the current URL without server or mode banners", async () => {
    const { render, screen } = await createDOM();
    await render(<Root initialView="conversions" />);

    expect(screen.querySelector("h1")?.textContent).toBe("Conversions");
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

    expect(screen.querySelector(".topbar")).toBeUndefined();
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

  it("shows waiting discs as a compact queue under the active progress", async () => {
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
                ? { available: true, pending: [], processed: [], failed: [] }
                : path.endsWith("/conversions")
                  ? {
                      available: true,
                      progress: {
                        state: "converting",
                        conversions: [
                          {
                            title: "Active Film (2000)",
                            mediaKind: "movie",
                            percent: 42,
                            detail: "Encoding DVD title 1",
                          },
                        ],
                        queued: [
                          "Another Film 1999.iso",
                          "A Series S2 Disc 1.iso",
                        ],
                      },
                    }
                  : {};
        return new Response(JSON.stringify(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="conversions" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Active Film (2000)"),
    );
    expect(screen.textContent).toContain("In queue (2)");
    expect(screen.textContent).toContain("Another Film 1999.iso");
    expect(screen.textContent).toContain("A Series S2 Disc 1.iso");
  });
});

describe("Media Manager library browser", () => {
  afterEach(() => vi.unstubAllGlobals());

  function libraryFetchMock(items: unknown[], canEdit = false) {
    return vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      const payload = path.endsWith("/status")
        ? { mutationMode: "enabled", integrations: [] }
        : path.endsWith("/session")
          ? { username: "dsaw", groups: ["users"], canEdit }
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

  it("starts library content without redundant panel headings", async () => {
    vi.stubGlobal("fetch", libraryFetchMock([]));

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    expect(
      screen.querySelector(".root-picker > .panel-heading"),
    ).toBeUndefined();
    expect(
      screen.querySelector(".catalog-panel > .catalog-heading"),
    ).toBeUndefined();
    expect(screen.textContent).not.toContain("Media roots");
    expect(screen.textContent).not.toContain("Videos (shared)");
  });

  it("renders roots without availability dots", async () => {
    vi.stubGlobal("fetch", libraryFetchMock([]));

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    expect(
      screen.querySelector(".root-picker .availability-dot"),
    ).toBeUndefined();
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

  it("parses a Jellyfin TV filename into editable fields", async () => {
    const items = [
      {
        id: "episode-1",
        rootId: "shared-videos",
        relativePath: "Awesome TV Show (2024) S01E07 The Return.mkv",
        mediaKind: "video",
        sizeBytes: 2048,
      },
    ];
    vi.stubGlobal("fetch", libraryFetchMock(items, true));

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-tab")).toBeDefined(),
    );

    const renameTab = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Rename",
    );
    await userEvent(renameTab ?? null, "click");

    expect(screen.querySelectorAll(".number-field input")).toHaveLength(2);
    expect(
      screen.querySelector(".title-field input")?.getAttribute("value"),
    ).toBe("Awesome TV Show");
    expect(
      screen.querySelector(".year-field input")?.getAttribute("value"),
    ).toBe("2024");
    const numberFields = Array.from(
      screen.querySelectorAll(".number-field input"),
    ) as HTMLInputElement[];
    expect(numberFields.map((field) => field.getAttribute("value"))).toEqual([
      "01",
      "07",
    ]);
    expect(
      screen.querySelector(".detail-field input")?.getAttribute("value"),
    ).toBe("The Return");
    expect(screen.querySelector(".media-image figcaption")).toBeUndefined();
    expect(
      screen.querySelector(".catalog-panel > .catalog-scroll-region"),
    ).toBeDefined();
    expect(
      screen.querySelector(".library-layout > .editor-card"),
    ).toBeDefined();
  });

  it("loads metadata into the editor when an item is selected", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Example Movie (2020).mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      const payload = path.endsWith("/status")
        ? { mutationMode: "enabled", integrations: [] }
        : path.endsWith("/session")
          ? { username: "dsaw", groups: ["users"], canEdit: true }
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
              ? { items }
              : path.endsWith("/metadata")
                ? {
                    mediaType: "movie",
                    title: "Example Movie",
                    year: 2020,
                    language: "en",
                    genres: ["Drama"],
                    runtimeMinutes: 120,
                    sources: ["filename", "nfo"],
                    providerIds: { imdb: "tt0000000" },
                  }
                : { available: false, progress: {} };
      return new Response(JSON.stringify(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(
        screen
          .querySelector(".metadata-form .title-input input")
          ?.getAttribute("value"),
      ).toBe("Example Movie"),
    );
    expect(
      screen.querySelector(".editor-tab.active")?.textContent?.trim(),
    ).toBe("Metadata");
    expect(
      screen.querySelector(".metadata-form select")?.getAttribute("value"),
    ).toBe("movie");
    expect(screen.textContent).toContain("IMDB");
    expect(screen.textContent).toContain("tt0000000");
    expect(screen.textContent).toContain("Sources: filename + nfo");
  });

  it("looks up a music release on MusicBrainz and fills the form from it", async () => {
    const items = [
      {
        id: "music-1",
        rootId: "shared-music",
        relativePath: "_Music/Nirvana - Nevermind.flac",
        mediaKind: "music",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? {
              mutationMode: "enabled",
              integrations: [
                {
                  id: "musicbrainz",
                  label: "MusicBrainz Picard",
                  available: true,
                  capabilities: [
                    "musicbrainz-lookup",
                    "musicbrainz-fingerprint",
                  ],
                },
              ],
            }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: true }
            : path.endsWith("/roots")
              ? [
                  {
                    id: "shared-music",
                    label: "Shared music",
                    category: "music",
                    scope: "shared",
                    available: true,
                  },
                ]
              : path.includes("/items?rootId=shared-music")
                ? { items }
                : path.endsWith("/metadata")
                  ? {
                      mediaType: "music",
                      title: "Smells Like Teen Spirit",
                      year: 1991,
                      language: "en",
                      sources: ["filename"],
                    }
                  : path.endsWith("/metadata/lookup")
                    ? {
                        requestId: "r1",
                        candidates: [
                          {
                            releaseGroupId:
                              "1b022e01-4da6-387b-8658-8678046e4cef",
                            artist: "Nirvana",
                            title: "Nevermind",
                            releaseType: "Album",
                            year: 1991,
                            genres: ["grunge", "alternative rock"],
                            label: "DGC",
                            trackCount: 13,
                            matchMethod: "search",
                          },
                        ],
                      }
                    : { available: false, progress: {} };
        return new Response(JSON.stringify(payload));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-music" />);

    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".musicbrainz-panel")).toBeDefined(),
    );
    expect(screen.textContent).toContain("MusicBrainz lookup");
    expect(screen.textContent).toContain("Fingerprint ready");

    await userEvent(
      screen.querySelector(".musicbrainz-panel .primary-button"),
      "click",
    );

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Nirvana — Nevermind"),
    );
    expect(screen.textContent).toContain("Album");
    expect(screen.textContent).toContain("DGC");
    expect(screen.textContent).toContain("13 tracks");
    expect(screen.textContent).toContain("matched by search");

    const fillButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Fill form",
    );
    await userEvent(fillButton ?? null, "click");

    await vi.waitFor(() =>
      expect(
        screen
          .querySelector(".editor-metadata-form .title-input input")
          ?.getAttribute("value"),
      ).toBe("Nevermind"),
    );
    const mainForm = screen.querySelector(".editor-metadata-form");
    expect(mainForm).toBeDefined();
    const fieldValue = (labelText: string): string | null => {
      const label = Array.from(mainForm?.querySelectorAll("label") ?? []).find(
        (element) =>
          element.querySelector("span")?.textContent?.includes(labelText),
      );
      return label?.querySelector("input")?.getAttribute("value") ?? null;
    };
    expect(fieldValue("Authors / artists")).toBe("Nirvana");
    expect(fieldValue("Year")).toBe("1991");
    expect(fieldValue("Genres")).toBe("grunge, alternative rock");
    expect(fieldValue("Publisher / studio")).toBe("DGC");
    expect(
      fetchMock.mock.calls.some(
        ([callInput, callInit]) =>
          String(callInput).endsWith("/metadata/lookup") &&
          String(callInit?.body).includes('"mode":"auto"'),
      ),
    ).toBe(true);
  });
});

describe("Jellyfin TV filename parsing", () => {
  it("separates the documented series, year, season, episode, and title", () => {
    expect(
      parseTvEpisodeFilename("Awesome TV Show (2024) S01E07 The Return.mkv"),
    ).toEqual({
      title: "Awesome TV Show",
      year: "2024",
      season: "01",
      episode: "07",
      episodeTitle: "The Return",
    });
  });

  it("also parses the manager's existing hyphenated Jellyfin-compatible names", () => {
    expect(
      parseTvEpisodeFilename(
        "Example Show (2020) - S02E003 - A New Beginning.mkv",
      ),
    ).toEqual({
      title: "Example Show",
      year: "2020",
      season: "02",
      episode: "003",
      episodeTitle: "A New Beginning",
    });
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
