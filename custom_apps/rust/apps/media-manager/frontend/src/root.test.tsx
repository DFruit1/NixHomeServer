import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root, {
  initialRouteFromSearch,
  itemFromSearch,
  metadataFieldChanges,
  metadataSourceChoices,
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
    expect(viewFromSearch("?view=health")).toBe("health");
    expect(viewFromSearch("?view=subtitles")).toBe("library");
    expect(viewFromSearch("?view=accounts")).toBe("accounts");
    expect(viewFromSearch("?view=overview")).toBe("library");
    expect(viewFromSearch("?view=unknown")).toBe("library");
    expect(rootFromSearch("?view=library&root=shared-videos")).toBe(
      "shared-videos",
    );
    expect(itemFromSearch("?view=library&root=shared-videos&item=item-1")).toBe(
      "item-1",
    );
    expect(
      initialRouteFromSearch("?view=library&root=shared-videos&item=item-1"),
    ).toEqual({
      initialView: "library",
      initialRootId: "shared-videos",
      initialItemId: "item-1",
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
              : path.includes("/items?rootId=shared-videos")
                ? { items: [] }
                : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root />);

    const expectedLinks = new Map([
      ["Libraries", "?view=library"],
      ["Library health", "?view=health"],
      ["Conversions", "?view=conversions"],
      ["Metadata sources", "?view=accounts"],
      ["App refresh", "?view=refresh"],
    ]);

    for (const [label, href] of expectedLinks) {
      const link = Array.from(screen.querySelectorAll("a.nav-item")).find(
        (element) => element.textContent?.trim() === label,
      );
      expect(link, `${label} navigation link`).toBeDefined();
      expect(link?.getAttribute("href")).toBe(href);
    }
    expect(screen.querySelector('a[href="?view=subtitles"]')).toBeFalsy();
    expect(screen.textContent).not.toContain("Overview");
  });

  it("shows actionable metadata issues with a direct editor link", async () => {
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
              : path.includes(
                    "/metadata/issues?rootId=shared-videos&pageSize=20",
                  )
                ? {
                    rootId: "shared-videos",
                    inspectedItems: 1,
                    issueCount: 1,
                    severityCounts: { error: 0, warning: 1, info: 0 },
                    nextCursor: null,
                    results: [
                      {
                        itemId: "arrival",
                        rootId: "shared-videos",
                        relativePath:
                          "Movies/Arrival (2016)/Arrival (2016).mkv",
                        mediaKind: "video",
                        health: [
                          {
                            code: "conflicting-title",
                            severity: "warning",
                            field: "title",
                            title: "Conflicting title",
                            message:
                              "Metadata sources disagree about the title.",
                            sources: ["filename", "sidecar"],
                          },
                        ],
                      },
                    ],
                  }
                : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="health" initialRootId="shared-videos" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Conflicting title"),
    );
    expect(screen.textContent).toContain("Arrival (2016).mkv");
    expect(screen.textContent).toContain("1 issue across 1 inspected item");
    expect(
      screen.querySelector("a.health-review-link")?.getAttribute("href"),
    ).toBe("?view=library&root=shared-videos&item=arrival");
  });

  it("renders a section selected by the current URL without server or mode banners", async () => {
    const { render, screen } = await createDOM();
    await render(<Root initialView="conversions" />);

    expect(screen.querySelector("h1")?.textContent).toBe("Conversions");
    expect(screen.textContent).not.toContain("Sydney Basiniot Media Server");
    expect(screen.textContent).not.toContain("Staged changes enabled");
    expect(screen.querySelector(".mode-pill")).toBeUndefined();
  });

  it("renders runtime provider accounts without attempting to reveal saved values", async () => {
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (
          path.endsWith("/provider-accounts/tmdb") &&
          init?.method === "PUT"
        ) {
          return new Response(
            wireJson({
              provider: {
                id: "tmdb",
                name: "The Movie Database (TMDB)",
                mediaDomains: ["movies", "television"],
                setupKind: "apiKey",
                implementationStatus: "active",
                canConfigure: true,
                canTest: true,
                capabilities: ["search", "details"],
                credentialFields: [],
                setupUrl: "https://www.themoviedb.org/settings/api",
                documentationUrl:
                  "https://developer.themoviedb.org/docs/getting-started",
                notes: "Movie and television matching.",
                account: { state: "configured" },
              },
            }),
          );
        }
        if (
          path.endsWith("/provider-accounts/tmdb/test") &&
          init?.method === "POST"
        ) {
          return new Response(
            wireJson({
              providerId: "tmdb",
              status: "ready",
              message: "The provider accepted this account.",
              requestId: "test-1",
            }),
          );
        }
        const payload = path.endsWith("/status")
          ? { mutationMode: "enabled", integrations: [] }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: false }
            : path.endsWith("/roots")
              ? []
              : path.endsWith("/provider-accounts")
                ? {
                    schemaVersion: 1,
                    recoveryAdvice:
                      "Saved credentials cannot be viewed again. Keep the recovery copy in Vaultwarden, KeePassXC, or another password manager.",
                    providers: [
                      {
                        id: "tmdb",
                        name: "The Movie Database (TMDB)",
                        mediaDomains: ["movies", "television"],
                        setupKind: "apiKey",
                        implementationStatus: "active",
                        canConfigure: true,
                        canTest: true,
                        capabilities: ["search", "details"],
                        credentialFields: [
                          {
                            id: "apiKey",
                            label: "API key",
                            inputType: "password",
                            isRequired: true,
                            help: "Paste the key.",
                          },
                        ],
                        setupUrl: "https://www.themoviedb.org/settings/api",
                        documentationUrl:
                          "https://developer.themoviedb.org/docs/getting-started",
                        notes: "Movie and television matching.",
                        account: {
                          state: "configured",
                          updatedAt: 100,
                          lastTestStatus: "ready",
                        },
                      },
                    ],
                  }
                : { available: false, progress: {} };
        return new Response(wireJson(payload));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="accounts" />);

    expect(screen.textContent).toContain("Provider accounts");
    expect(screen.textContent).toContain("Vaultwarden");
    expect(screen.textContent).toContain("The Movie Database (TMDB)");
    expect(screen.textContent).not.toContain("saved-value");
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/provider-accounts",
      expect.objectContaining({ credentials: "same-origin" }),
    );
    const replace = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Replace credentials",
    );
    await userEvent(replace ?? null, "click");
    expect(
      screen.querySelector(".provider-setup-steps")?.textContent,
    ).toContain("Get access");
    expect(
      screen.querySelector(".provider-setup-steps")?.textContent,
    ).toContain("Enter credentials");
    expect(
      screen.querySelector(".provider-setup-steps")?.textContent,
    ).toContain("Save and test");
    expect(
      screen.querySelector(".provider-credential-footer button[type=submit]")
        ?.textContent,
    ).toContain("Save and test");
    expect(
      screen.querySelector<HTMLInputElement>(".provider-test-choice input")
        ?.checked,
    ).toBe(true);
    const apiKey = screen.querySelector<HTMLInputElement>(
      ".credential-field-grid input",
    );
    if (!apiKey) throw new Error("API key input missing");
    apiKey.value = "new-runtime-key";
    await userEvent(apiKey, "input");
    await userEvent(
      screen.querySelector(".provider-credential-editor form"),
      "submit",
    );
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("saved and connected"),
    );
    expect(screen.querySelector(".provider-credential-editor")).toBeUndefined();
    expect(
      fetchMock.mock.calls.some(
        ([input, request]) =>
          String(input).endsWith("/provider-accounts/tmdb/test") &&
          request?.method === "POST",
      ),
    ).toBe(true);

    const refreshedReplace = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Replace credentials",
    );
    await userEvent(refreshedReplace ?? null, "click");
    const testAfterSave = screen.querySelector<HTMLInputElement>(
      ".provider-test-choice input",
    );
    if (!testAfterSave) throw new Error("test-after-save choice missing");
    testAfterSave.checked = false;
    await userEvent(testAfterSave, "change");
    expect(
      screen.querySelector(".provider-credential-footer button[type=submit]")
        ?.textContent,
    ).toContain("Encrypt and save");
    const replacementKey = screen.querySelector<HTMLInputElement>(
      ".credential-field-grid input",
    );
    if (!replacementKey) throw new Error("replacement API key input missing");
    replacementKey.value = "save-without-test-key";
    await userEvent(replacementKey, "input");
    await userEvent(
      screen.querySelector(".provider-credential-editor form"),
      "submit",
    );
    await vi.waitFor(() =>
      expect(
        screen.querySelector(".provider-credential-editor"),
      ).toBeUndefined(),
    );
    expect(
      fetchMock.mock.calls.filter(
        ([input, request]) =>
          String(input).endsWith("/provider-accounts/tmdb/test") &&
          request?.method === "POST",
      ),
    ).toHaveLength(1);
  });

  it("separates usable sources from planned adapters and never offers planned setup", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        const payload = path.endsWith("/status")
          ? { mutationMode: "enabled", integrations: [] }
          : path.endsWith("/session")
            ? { username: "dsaw", groups: ["users"], canEdit: true }
            : path.endsWith("/roots")
              ? []
              : path.endsWith("/provider-accounts")
                ? {
                    schemaVersion: 1,
                    recoveryAdvice: "Keep a recovery copy.",
                    providers: [
                      {
                        id: "tmdb",
                        name: "The Movie Database (TMDB)",
                        mediaDomains: ["movies", "television"],
                        setupKind: "apiKey",
                        implementationStatus: "active",
                        canConfigure: true,
                        canTest: true,
                        capabilities: ["search", "details"],
                        credentialFields: [
                          {
                            id: "apiKey",
                            label: "API key",
                            inputType: "password",
                            isRequired: true,
                            help: "Paste the key.",
                          },
                        ],
                        setupUrl: "https://www.themoviedb.org/settings/api",
                        documentationUrl:
                          "https://developer.themoviedb.org/docs/getting-started",
                        notes: "Movie and television matching.",
                        account: {
                          state: "configured",
                          lastTestStatus: "rejected",
                        },
                      },
                      {
                        id: "tvdb",
                        name: "TheTVDB",
                        mediaDomains: ["television"],
                        setupKind: "account",
                        implementationStatus: "planned",
                        canConfigure: false,
                        canTest: false,
                        capabilities: ["search", "episodes"],
                        credentialFields: [
                          {
                            id: "apiKey",
                            label: "API key",
                            inputType: "password",
                            isRequired: true,
                            help: "Paste the key.",
                          },
                        ],
                        setupUrl: "https://thetvdb.com/api-information",
                        documentationUrl: "https://github.com/thetvdb/v4-api",
                        notes: "Alternate episode ordering.",
                        account: { state: "notConfigured" },
                      },
                      {
                        id: "open-library",
                        name: "Open Library",
                        mediaDomains: ["books", "audiobooks"],
                        setupKind: "public",
                        implementationStatus: "planned",
                        canConfigure: false,
                        canTest: false,
                        capabilities: ["search", "isbn"],
                        credentialFields: [],
                        setupUrl: "https://openlibrary.org/",
                        documentationUrl:
                          "https://openlibrary.org/developers/api",
                        notes: "Public bibliographic records.",
                        account: { state: "notRequired" },
                      },
                    ],
                  }
                : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="accounts" />);
    await vi.waitFor(() => expect(screen.textContent).toContain("TMDB"));

    expect(screen.textContent).not.toContain("TheTVDB");
    const comingSoon = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Coming soon",
    );
    await userEvent(comingSoon ?? null, "click");
    await vi.waitFor(() => expect(screen.textContent).toContain("TheTVDB"));
    const plannedCard = Array.from(
      screen.querySelectorAll(".provider-account-card"),
    ).find((card) => card.textContent?.includes("TheTVDB"));
    expect(plannedCard?.textContent).not.toContain("Set up");
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
      return new Response(wireJson(payload));
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
      return new Response(wireJson(payload));
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

  it("exposes every category as a selectable library tab", async () => {
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
              : path.includes("/items?rootId=")
                ? { items: [] }
                : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const tabs = Array.from(screen.querySelectorAll(".library-tab"));
    const labels = tabs.map((tab) => tab.textContent?.trim());
    expect(labels).toEqual([
      "Videos",
      "Music",
      "Audiobooks",
      "Podcasts",
      "Books",
    ]);
    expect(tabs[0]?.getAttribute("aria-selected")).toBe("true");
    expect(tabs[1]?.getAttribute("aria-selected")).toBe("false");
    expect(tabs[2]?.classList.contains("disabled")).toBe(true);
    expect(tabs[3]?.classList.contains("disabled")).toBe(true);
    expect(tabs[4]?.classList.contains("disabled")).toBe(true);
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
            wireJson({
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
        return new Response(wireJson(payload), {
          status: init?.method === "POST" ? 202 : 200,
        });
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
        return new Response(wireJson(payload));
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
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root initialView="conversions" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("EXAMPLE_MOVIE"),
    );
    expect(screen.textContent).toContain("MOVIE_DISC.ISO");
    expect(screen.textContent).toContain("Processed");
    expect(screen.textContent).toContain("Failed");
    expect(screen.textContent).toContain("OLD_MOVIE.ISO");
    expect(screen.textContent).toContain(
      "Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.",
    );
    expect(screen.textContent).toContain("No failed conversions.");
    expect(screen.querySelector("main")?.classList).toContain(
      "main-content--conversions",
    );
    const processedRegion = screen.querySelector(
      '[role="region"][aria-labelledby="processed-heading"]',
    );
    const failedRegion = screen.querySelector(
      '[role="region"][aria-labelledby="failed-heading"]',
    );
    expect(processedRegion?.getAttribute("tabindex")).toBe("0");
    expect(failedRegion?.getAttribute("tabindex")).toBe("0");
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
        return new Response(wireJson(payload));
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
              ? {
                  items: items.filter(
                    (item) =>
                      (item as { rootId?: string }).rootId ===
                      decodeURIComponent(path.split("rootId=")[1] ?? ""),
                  ),
                }
              : { available: false, progress: {} };
      return new Response(wireJson(payload));
    });
  }

  it("opens a metadata item selected by a durable library URL", async () => {
    const item = {
      id: "arrival",
      rootId: "shared-videos",
      relativePath: "Movies/Arrival (2016)/Arrival (2016).mkv",
      mediaKind: "video",
      sizeBytes: 1024,
    };
    const libraryFetch = libraryFetchMock([]);
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).endsWith("/items/arrival")) {
        return new Response(wireJson(item));
      }
      return libraryFetch(input);
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render } = await createDOM();
    await render(
      <Root
        initialView="library"
        initialRootId="shared-videos"
        initialItemId="arrival"
      />,
    );

    await vi.waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/v1/items/arrival/metadata",
        expect.objectContaining({ credentials: "same-origin" }),
      ),
    );
  });

  it("splits library content into Personal and Shared panes", async () => {
    vi.stubGlobal("fetch", libraryFetchMock([]));

    const { render, screen } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const headings = Array.from(
      screen.querySelectorAll(".pane-heading h3"),
    ).map((heading) => heading.textContent);
    expect(headings).toEqual(["Personal", "Shared"]);
    expect(
      screen.querySelectorAll(".catalog-panel").length,
    ).toBeGreaterThanOrEqual(2);
    expect(screen.textContent).not.toContain("Shared videos");
    expect(screen.textContent).not.toContain("My videos");
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

  it("selects folder names separately from caret-only expansion", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Example Movie (2020).mkv",
        mediaKind: "video",
        sizeBytes: 1024,
      },
      {
        id: "episode-1",
        rootId: "shared-videos",
        relativePath: "_Shows/Example Show/Season 01/Episode.mkv",
        mediaKind: "video",
        sizeBytes: 2048,
      },
      {
        id: "cover-1",
        rootId: "shared-videos",
        relativePath: "_Movies/cover.jpg",
        mediaKind: "artwork",
        sizeBytes: 8192,
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
              : path.includes("/folders/metadata?")
                ? {
                    mediaType: "movie",
                    title: "Movies",
                    language: "en",
                    sources: ["folder"],
                  }
                : { available: false, progress: {} };
      return new Response(wireJson(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const sharedPane = screen.querySelectorAll(".catalog-panel")[1];
    const folderRow = (name: string) =>
      Array.from(sharedPane?.querySelectorAll(".tree-row.folder") ?? []).find(
        (row) => row.querySelector(".tree-name")?.textContent === name,
      );
    const movieBranch = folderRow("_Movies")?.closest(".tree-branch");
    const showBranch = folderRow("_Shows")?.closest(".tree-branch");
    expect(movieBranch?.getAttribute("aria-expanded")).toBe("true");

    await userEvent(showBranch?.querySelector(".tree-toggle") ?? null, "click");
    expect(showBranch?.getAttribute("aria-expanded")).toBe("false");

    const tree = sharedPane?.querySelector(".item-tree") as HTMLElement;
    tree.scrollTop = 240;
    await userEvent(showBranch?.querySelector(".tree-toggle") ?? null, "click");

    expect(showBranch?.getAttribute("aria-expanded")).toBe("true");
    expect(movieBranch?.getAttribute("aria-expanded")).toBe("false");
    expect(folderRow("_Movies")?.classList.contains("sibling-muted")).toBe(
      true,
    );
    expect(tree.scrollTop).toBe(0);

    await userEvent(
      folderRow("_Movies")?.querySelector(".tree-folder-name") ?? null,
      "click",
    );

    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining(
        "/api/v1/folders/metadata?rootId=shared-videos&relativePath=_Movies",
      ),
      expect.objectContaining({ credentials: "same-origin" }),
    );
    expect(
      screen.querySelector<HTMLImageElement>(".media-image img")?.src,
    ).toContain("/items/movie-1/image");
  });

  it("replaces the opposite library pane with details and focuses the selected folder", async () => {
    const items = [
      ...Array.from({ length: 5 }, (_, index) => ({
        id: `geology-${index + 1}`,
        rootId: "shared-videos",
        relativePath: `_Movies/AiG Geology (2009)/AiG Geology S01E0${index + 1}.mkv`,
        mediaKind: "video",
        sizeBytes: 1024 * (index + 1),
      })),
      {
        id: "other-movie",
        rootId: "shared-videos",
        relativePath: "_Movies/Another Film (2010)/Another Film (2010).mkv",
        mediaKind: "video",
        sizeBytes: 8192,
      },
      {
        id: "personal-video",
        rootId: "personal-videos",
        relativePath: "_YouTube/ThunderScott/Example.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    vi.stubGlobal("fetch", libraryFetchMock(items, true));

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    const aigFolder = Array.from(
      screen.querySelectorAll(".shared-pane .tree-folder-name"),
    ).find((button) => button.textContent?.trim() === "AiG Geology (2009)");
    await userEvent(aigFolder ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".library-detail-pane")).toBeDefined(),
    );
    expect(screen.querySelectorAll(".catalog-panel")).toHaveLength(1);
    expect(screen.querySelector(".personal-pane")).toBeUndefined();
    expect(screen.querySelector(".shared-pane")).toBeDefined();
    expect(
      screen.querySelector(".library-detail-pane.detail-personal"),
    ).toBeDefined();
    expect(
      screen.querySelector('[aria-label="Selected shared library details"]'),
    ).toBeDefined();
    expect(
      screen.querySelector(".library-detail-pane .root-picker-image"),
    ).toBeDefined();
    expect(
      screen.querySelector(".library-detail-pane .editor-card"),
    ).toBeDefined();

    const focusedPane = screen.querySelector(".shared-pane");
    expect(focusedPane?.textContent).toContain("AiG Geology (2009)");
    expect(focusedPane?.querySelectorAll(".tree-row.file")).toHaveLength(5);
    expect(focusedPane?.textContent).not.toContain("_Movies");
    expect(focusedPane?.textContent).not.toContain("Another Film (2010)");

    await userEvent(
      screen.querySelector('[aria-label="Close item editor"]'),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".personal-pane")).toBeDefined(),
    );
    const personalFolder = Array.from(
      screen.querySelectorAll(".personal-pane .tree-folder-name"),
    ).find((button) => button.textContent?.trim() === "ThunderScott");
    await userEvent(personalFolder ?? null, "click");

    await vi.waitFor(() =>
      expect(
        screen.querySelector(".library-detail-pane.detail-shared"),
      ).toBeDefined(),
    );
    expect(screen.querySelector(".shared-pane")).toBeUndefined();
    expect(screen.querySelector(".personal-pane")).toBeDefined();
    expect(
      screen.querySelector('[aria-label="Selected personal library details"]'),
    ).toBeDefined();
    expect(screen.querySelector(".personal-pane")?.textContent).not.toContain(
      "_YouTube",
    );
    expect(
      screen
        .querySelector(".personal-pane")
        ?.querySelectorAll(".tree-row.file"),
    ).toHaveLength(1);
  });

  it("shows checked image sources and stages an upload inside a missing-image placeholder", async () => {
    const items = [
      {
        id: "video-1",
        rootId: "shared-videos",
        relativePath: "A long collection/Movie.mkv",
        mediaKind: "video",
        sizeBytes: 1024,
      },
      {
        id: "subtitle-1",
        rootId: "shared-videos",
        relativePath: "A long collection/A subtitle.srt",
        mediaKind: "subtitle",
        sizeBytes: 128,
      },
    ];
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path.endsWith("/image/sources"))
          return new Response(
            wireJson({
              sources: [
                { id: "sidecar", label: "Sidecar image", status: "missing" },
                {
                  id: "embedded",
                  label: "Embedded image",
                  status: "available",
                },
                { id: "jellyfin", label: "Jellyfin export", status: "unknown" },
              ],
            }),
          );
        if (path.includes("/image/replacement?"))
          return new Response(
            wireJson({
              id: "image-plan",
              digest: "image-digest",
              warnings: ["A new cover image will be installed."],
            }),
            { status: 201 },
          );
        if (path.endsWith("/confirm"))
          return new Response(wireJson({ id: "image-plan", state: "queued" }), {
            status: 202,
          });
        return libraryFetchMock(items, true)(input);
      },
    );
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(
      <Root
        initialView="library"
        initialRootId="shared-videos"
        initialItemId="video-1"
      />,
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".media-image img")).toBeTruthy(),
    );
    await userEvent(screen.querySelector(".media-image img"), "error");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Jellyfin export"),
    );
    const placeholder = screen.querySelector(".media-image-placeholder");
    expect(placeholder?.textContent).toContain("Image found");
    expect(placeholder?.textContent).toContain("Not found");
    expect(placeholder?.textContent).toContain("Not reported");
    expect(placeholder?.textContent).toContain("Upload image from device");
    expect(screen.querySelector(".tree-row.folder.wrap-title")).toBeTruthy();
    const input = placeholder?.querySelector("input[type=file]");
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [{ name: "cover.png", type: "image/png" }],
    });
    await userEvent(input ?? null, "change");
    await vi.waitFor(() =>
      expect(placeholder?.textContent).toContain("Confirm replacement"),
    );
    const confirm = Array.from(
      placeholder?.querySelectorAll("button") ?? [],
    ).find((button) => button.textContent?.includes("Confirm replacement"));
    await userEvent(confirm ?? null, "click");
    expect(
      fetchMock.mock.calls.some(
        ([path, init]) =>
          String(path).endsWith("/plans/image-plan/confirm") &&
          init?.method === "POST",
      ),
    ).toBe(true);
    await userEvent(screen.querySelector(".tree-folder-name"), "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector(".media-image-placeholder")?.textContent,
      ).toContain("Upload image from device"),
    );
    expect(screen.querySelectorAll(".tree-row.file.wrap-title")).toHaveLength(
      2,
    );
  });

  it("shows a benign cover-art card instead of requesting media metadata", async () => {
    const items = [
      {
        id: "cover-1",
        rootId: "shared-videos",
        relativePath: "cover.jpg",
        mediaKind: "artwork",
        sizeBytes: 8192,
      },
    ];
    const fetchMock = libraryFetchMock(items, true);
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const sharedPane = screen.querySelectorAll(".catalog-panel")[1];

    await userEvent(
      sharedPane?.querySelector(".tree-row.file") ?? null,
      "click",
    );

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Image File (Cover Art)"),
    );
    expect(screen.textContent).toContain("Replace cover art");
    expect(screen.querySelector(".non-media-card")).toBeDefined();
    expect(screen.querySelector(".message.error")).toBeUndefined();
    expect(
      fetchMock.mock.calls.some(([input]) =>
        String(input).endsWith("/items/cover-1/metadata"),
      ),
    ).toBe(false);
  });

  it("discards an artwork preview that resolves after another image is selected", async () => {
    const items = [
      {
        id: "cover-a",
        rootId: "shared-videos",
        relativePath: "A-cover.jpg",
        mediaKind: "artwork",
        sizeBytes: 8192,
      },
      {
        id: "cover-b",
        rootId: "shared-videos",
        relativePath: "B-cover.jpg",
        mediaKind: "artwork",
        sizeBytes: 8192,
      },
    ];
    let resolveUpload!: (response: Response) => void;
    const uploadResponse = new Promise<Response>((resolve) => {
      resolveUpload = resolve;
    });
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.includes("/image/replacement?")) return uploadResponse;
      return libraryFetchMock(items, true)(input);
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const fileButton = (name: string) =>
      Array.from(
        screen.querySelectorAll<HTMLButtonElement>(
          ".shared-pane .tree-row.file",
        ),
      ).find(
        (button) => button.querySelector(".tree-name")?.textContent === name,
      );
    await userEvent(fileButton("A-cover.jpg") ?? null, "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector(".non-media-card input[type=file]"),
      ).toBeTruthy(),
    );
    const input = screen.querySelector<HTMLInputElement>(
      ".non-media-card input[type=file]",
    );
    const file = { name: "cover.png", type: "image/png" } as File;
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [file],
    });
    const uploadChange = userEvent(input, "change");
    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([request]) =>
          String(request).includes("/items/cover-a/image/replacement?"),
        ),
      ).toBe(true),
    );

    await userEvent(fileButton("B-cover.jpg") ?? null, "click");
    resolveUpload(
      new Response(wireJson({ id: "plan-a", digest: "a".repeat(64) }), {
        status: 201,
      }),
    );
    await uploadChange;
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(screen.textContent).not.toContain("Confirm replacement");
    expect(screen.textContent).toContain("B-cover.jpg");
  });

  it("discards a folder sidecar preview that resolves after another folder is selected", async () => {
    const items = [
      {
        id: "alpha-episode",
        rootId: "shared-videos",
        relativePath: "_Shows/Alpha/Episode.mkv",
        mediaKind: "video",
        sizeBytes: 1024,
      },
      {
        id: "beta-episode",
        rootId: "shared-videos",
        relativePath: "_Shows/Beta/Episode.mkv",
        mediaKind: "video",
        sizeBytes: 1024,
      },
    ];
    let resolvePreview!: (response: Response) => void;
    const previewResponse = new Promise<Response>((resolve) => {
      resolvePreview = resolve;
    });
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (
        path.includes("/folders/metadata/sidecar?") &&
        path.includes("relativePath=_Shows%2FAlpha")
      ) {
        return previewResponse;
      }
      if (path.includes("relativePath=_Shows%2FAlpha")) {
        return new Response(
          wireJson({
            mediaType: "series",
            title: "Alpha current",
            sources: ["folder"],
          }),
        );
      }
      if (path.includes("relativePath=_Shows%2FBeta")) {
        return new Response(
          wireJson({
            mediaType: "series",
            title: "Beta current",
            sources: ["folder"],
          }),
        );
      }
      return libraryFetchMock(items, true)(input);
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const folderButton = (name: string) =>
      Array.from(
        screen.querySelectorAll<HTMLButtonElement>(
          ".shared-pane .tree-folder-name",
        ),
      ).find((button) => button.textContent === name);
    expect(folderButton("Alpha")).toBeDefined();
    expect(folderButton("Beta")).toBeDefined();
    await userEvent(folderButton("Alpha") ?? null, "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector<HTMLInputElement>(".title-input input")?.value,
      ).toBe("Alpha current"),
    );
    const previewClick = userEvent(
      Array.from(screen.querySelectorAll("button")).find((button) =>
        button.textContent?.includes("Preview metadata sidecar"),
      ) ?? null,
      "click",
    );
    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(
          ([request]) =>
            String(request).includes("/folders/metadata/sidecar?") &&
            String(request).includes("relativePath=_Shows%2FAlpha"),
        ),
      ).toBe(true),
    );
    await userEvent(
      screen.querySelector('[aria-label="Close item editor"]'),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".library-detail-pane")).toBeUndefined(),
    );
    await userEvent(folderButton("Beta") ?? null, "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector<HTMLInputElement>(".title-input input")?.value,
      ).toBe("Beta current"),
    );

    resolvePreview(
      new Response(
        wireJson({
          id: "alpha-plan",
          digest: "a".repeat(64),
          expiresAt: 9999999999,
          actions: [
            {
              kind: "install_metadata_sidecar",
              destinationRelativePath: "_Shows/Alpha/tvshow.nfo",
            },
          ],
          warnings: [],
        }),
        { status: 201 },
      ),
    );
    await previewClick;
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(screen.textContent).not.toContain("Confirm metadata");
  });

  it("clears a selected folder when switching media categories", async () => {
    const roots = [
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
    ];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      const payload = path.endsWith("/status")
        ? { mutationMode: "enabled", integrations: [] }
        : path.endsWith("/session")
          ? { username: "dsaw", groups: ["users"], canEdit: true }
          : path.endsWith("/roots")
            ? roots
            : path.includes("rootId=shared-videos")
              ? {
                  items: [
                    {
                      id: "video-1",
                      rootId: "shared-videos",
                      relativePath: "Collection/Film.mkv",
                      mediaKind: "video",
                      sizeBytes: 1024,
                    },
                  ],
                }
              : path.includes("rootId=shared-music")
                ? {
                    items: [
                      {
                        id: "music-1",
                        rootId: "shared-music",
                        relativePath: "Collection/Track.flac",
                        mediaKind: "music",
                        sizeBytes: 1024,
                      },
                    ],
                  }
                : path.includes("/folders/metadata?")
                  ? { mediaType: "movie", title: "Collection" }
                  : { available: false, progress: {} };
      return new Response(wireJson(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(
      screen.querySelector(".shared-pane .tree-folder-name"),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );
    await userEvent(
      Array.from(screen.querySelectorAll(".library-tab")).find(
        (tab) => tab.textContent?.trim() === "Music",
      ) ?? null,
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeUndefined(),
    );
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
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );

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
      screen.querySelector(".library-detail-pane > .editor-card"),
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
                    sources: ["filename", "sidecar", "jellyfin"],
                    providerIds: { imdb: "tt0000000" },
                    fieldSources: { title: "sidecar", year: "filename" },
                    sidecar: {
                      relativePath: "_Movies/Example Movie (2020).nfo",
                      format: "nfo",
                      exists: true,
                      canReplace: true,
                      consumerEffective: true,
                    },
                    consumers: [
                      {
                        id: "jellyfin",
                        label: "Jellyfin",
                        available: true,
                        effect: "read-after-refresh",
                        canManageNatively: true,
                        portableWriteSupported: true,
                        message:
                          "Jellyfin reads correctly named local NFO files after a library refresh.",
                        nativeUrl: "https://videos.example.test",
                      },
                    ],
                    health: [
                      {
                        code: "conflicting-title",
                        severity: "warning",
                        field: "title",
                        title: "Title differs between sources",
                        message: "Choose the authoritative title.",
                        sources: ["filename", "sidecar"],
                      },
                    ],
                    modificationTargets: [
                      {
                        id: "portable-sidecar",
                        label: "Portable file metadata",
                        kind: "portable-file",
                        available: true,
                        recommended: true,
                        requiresRefresh: true,
                        message:
                          "Write an NFO that survives application rebuilds.",
                      },
                      {
                        id: "jellyfin-application",
                        label: "Jellyfin app metadata",
                        kind: "application-local",
                        available: true,
                        recommended: false,
                        requiresRefresh: false,
                        message: "Use Jellyfin's native editor.",
                      },
                    ],
                    inspectionWarnings: [],
                    observations: [
                      {
                        source: "filename",
                        label: "Filename",
                        storage: "filename",
                        consumedBy: ["jellyfin"],
                        survivesRescan: true,
                        writable: false,
                        fields: { title: "Example Movie", year: 2020 },
                      },
                      {
                        source: "sidecar",
                        label: "NFO sidecar",
                        format: "nfo",
                        relativePath: "_Movies/Example Movie (2020).nfo",
                        storage: "sidecar-file",
                        consumedBy: ["jellyfin"],
                        survivesRescan: true,
                        writable: true,
                        fields: { title: "Example Movie", genres: ["Drama"] },
                        rawPreview:
                          "<movie><title>Example Movie</title></movie>",
                      },
                      {
                        source: "jellyfin",
                        label: "Jellyfin",
                        storage: "application-database",
                        consumedBy: ["jellyfin"],
                        survivesRescan: false,
                        writable: false,
                        fields: {
                          title: "Example Movie: Restored",
                          genres: ["Drama", "Mystery"],
                        },
                      },
                    ],
                  }
                : { available: false, progress: {} };
      return new Response(wireJson(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);

    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".tmdb-panel")).toBeTruthy(),
    );
    expect(screen.textContent).toContain("The Movie Database");
    await vi.waitFor(() =>
      expect(
        screen
          .querySelector(".editor-metadata-form .title-input input")
          ?.getAttribute("value"),
      ).toBe("Example Movie"),
    );
    expect(
      screen
        .querySelector(".editor-metadata-form select")
        ?.getAttribute("value"),
    ).toBe("movie");
    expect(screen.textContent).toContain("IMDB");
    expect(screen.textContent).toContain("tt0000000");
    expect(screen.textContent).not.toContain(
      "Sources, differences, and write targets",
    );
    expect(screen.querySelector(".metadata-toolbar")?.textContent).toContain(
      "Create draft",
    );
    expect(screen.querySelector(".metadata-inspector")).toBeFalsy();
    await userEvent(
      Array.from(screen.querySelectorAll(".metadata-section-tab")).find(
        (button) => button.textContent?.trim() === "Advanced",
      ) ?? null,
      "click",
    );
    expect(screen.textContent).toContain("Sources and write targets");
    expect(screen.textContent).toContain("NFO sidecar");
    expect(screen.textContent).toContain("Jellyfin");
    expect(screen.textContent).toContain("Refresh after applying");
    expect(screen.textContent).toContain("Survives rescan");
    expect(screen.textContent).toContain("Metadata health");
    expect(screen.textContent).toContain("Title differs between sources");
    expect(screen.textContent).toContain("Portable file metadata");
    expect(screen.textContent).toContain("Jellyfin app metadata");
    expect(screen.textContent).toContain("Sources: filename + sidecar");
    expect(screen.querySelector(".metadata-inspector")?.tagName).toBe(
      "DETAILS",
    );
    expect(
      screen.querySelector(".metadata-inspector")?.hasAttribute("open"),
    ).toBe(false);
    expect(
      screen.querySelector(".editor-metadata-form")?.hasAttribute("disabled"),
    ).toBe(true);
    await userEvent(
      Array.from(screen.querySelectorAll(".metadata-section-tab")).find(
        (button) => button.textContent?.trim() === "Basics",
      ) ?? null,
      "click",
    );
    const draftButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create draft",
    );
    await userEvent(draftButton ?? null, "click");
    expect(
      screen.querySelector(".editor-metadata-form")?.hasAttribute("disabled"),
    ).toBe(false);
    expect(
      screen.querySelector(".metadata-source-choices")?.textContent,
    ).toContain("Choose source values");
    const jellyfinChoice = Array.from(
      screen.querySelectorAll<HTMLButtonElement>(".metadata-source-choice"),
    ).find(
      (button) =>
        button.textContent?.includes("Jellyfin") &&
        button.textContent.includes("Example Movie: Restored"),
    );
    expect(jellyfinChoice?.getAttribute("aria-label")).toBeNull();
    await userEvent(jellyfinChoice ?? null, "click");
    expect(
      screen.querySelector<HTMLInputElement>(
        ".editor-metadata-form .title-input input",
      )?.value,
    ).toBe("Example Movie: Restored");
  });

  it("keeps an unsaved metadata draft when switching items is cancelled", async () => {
    const items = [
      {
        id: "movie-a",
        rootId: "shared-videos",
        relativePath: "_Movies/Arrival.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
      {
        id: "movie-b",
        rootId: "shared-videos",
        relativePath: "_Movies/Contact.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    vi.stubGlobal(
      "confirm",
      vi.fn(() => false),
    );
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
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
                  {
                    id: "shared-music",
                    label: "Shared music",
                    category: "music",
                    scope: "shared",
                    available: true,
                  },
                ]
              : path.includes("/items?rootId=shared-videos")
                ? { items }
                : path.includes("/items?rootId=shared-music")
                  ? { items: [] }
                  : path.endsWith("/items/movie-a/metadata")
                    ? {
                        mediaType: "movie",
                        title: "Arrival",
                        language: "en",
                        sources: ["filename"],
                      }
                    : path.endsWith("/items/movie-b/metadata")
                      ? {
                          mediaType: "movie",
                          title: "Contact",
                          language: "en",
                          sources: ["filename"],
                        }
                      : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const fileButton = (name: string) =>
      Array.from(
        screen.querySelectorAll<HTMLButtonElement>(".tree-row.file"),
      ).find((button) => button.textContent?.includes(name));
    await userEvent(fileButton("Arrival.mkv") ?? null, "click");
    await vi.waitFor(() =>
      expect(
        screen
          .querySelector<HTMLInputElement>(
            ".editor-metadata-form .title-input input",
          )
          ?.getAttribute("value"),
      ).toBe("Arrival"),
    );
    const draftButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create draft",
    );
    await userEvent(draftButton ?? null, "click");
    const title = screen.querySelector<HTMLInputElement>(
      ".editor-metadata-form .title-input input",
    );
    if (!title) throw new Error("metadata title input missing");
    title.value = "Arrival — Director's Cut";
    await userEvent(title, "input");
    title.value = " Arrival ";
    await userEvent(title, "input");
    expect(screen.textContent).not.toContain("Discard changes");
    const inspectButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Inspect current",
    );
    await userEvent(inspectButton ?? null, "click");
    await vi.waitFor(() => expect(title.value).toBe("Arrival"));
    const nextDraftButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create draft",
    );
    await userEvent(nextDraftButton ?? null, "click");
    title.value = "Arrival — Director's Cut";
    await userEvent(title, "input");
    await userEvent(fileButton("Arrival.mkv") ?? null, "click");
    const activeCategory = Array.from(
      screen.querySelectorAll<HTMLButtonElement>(".library-tab"),
    ).find((button) => button.textContent?.trim() === "Videos");
    await userEvent(activeCategory ?? null, "click");

    await userEvent(
      screen.querySelector(".shared-pane .tree-folder-name"),
      "click",
    );
    const musicCategory = Array.from(
      screen.querySelectorAll<HTMLButtonElement>(".library-tab"),
    ).find((button) => button.textContent?.trim() === "Music");
    await userEvent(musicCategory ?? null, "click");
    await userEvent(fileButton("Contact.mkv") ?? null, "click");

    expect(globalThis.confirm).toHaveBeenCalledTimes(3);
    expect(
      screen
        .querySelector<HTMLInputElement>(
          ".editor-metadata-form .title-input input",
        )
        ?.getAttribute("value"),
    ).toBe("Arrival — Director's Cut");
    expect(fileButton("Arrival.mkv")?.classList.contains("selected")).toBe(
      true,
    );
  });

  it("shows field-level metadata changes in the confirmation preview", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Arrival.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    let sidecarRequests = 0;
    let confirmRequests = 0;
    let resolveStalePreview!: (response: Response) => void;
    const stalePreview = new Promise<Response>((resolve) => {
      resolveStalePreview = resolve;
    });
    let resolveConfirmation!: (response: Response) => void;
    const confirmation = new Promise<Response>((resolve) => {
      resolveConfirmation = resolve;
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (
          path.endsWith("/items/movie-1/metadata/sidecar") &&
          init?.method === "POST"
        ) {
          sidecarRequests += 1;
          if (sidecarRequests === 2) return stalePreview;
          return new Response(
            wireJson({
              id: "metadata-plan",
              digest: "a".repeat(64),
              expiresAt: Date.now() + 1_800_000,
              actions: [{ destinationRelativePath: "_Movies/Arrival.nfo" }],
              warnings: [],
            }),
            { status: 201 },
          );
        }
        if (
          path.endsWith("/plans/metadata-plan/confirm") &&
          init?.method === "POST"
        ) {
          confirmRequests += 1;
          return confirmation;
        }
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
                : path.endsWith("/items/movie-1/metadata")
                  ? {
                      mediaType: "movie",
                      title: "Arrival",
                      year: 2016,
                      language: "en",
                      genres: ["Drama"],
                      sources: ["filename"],
                    }
                  : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Create draft"),
    );
    const draftButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create draft",
    );
    await userEvent(draftButton ?? null, "click");
    const title = screen.querySelector<HTMLInputElement>(
      ".editor-metadata-form .title-input input",
    );
    if (!title) throw new Error("metadata title input missing");
    title.value = "Arrival — Director's Cut";
    await userEvent(title, "input");
    const previewButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Preview metadata sidecar",
    );
    await userEvent(previewButton ?? null, "click");

    await vi.waitFor(() =>
      expect(
        screen.querySelector(".metadata-change-review")?.textContent,
      ).toContain("Arrival — Director's Cut"),
    );
    expect(
      screen.querySelector(".metadata-change-review")?.textContent,
    ).toContain("Arrival");

    const confirmButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Confirm metadata",
    );
    const confirmClick = userEvent(confirmButton ?? null, "click");
    await vi.waitFor(() => expect(confirmRequests).toBe(1));
    title.value = "Arrival — Edited During Confirmation";
    await userEvent(title, "input");
    resolveConfirmation(
      new Response(wireJson({ id: "metadata-plan", state: "queued" }), {
        status: 202,
      }),
    );
    await confirmClick;
    expect(title.value).toBe("Arrival — Edited During Confirmation");
    expect(screen.textContent).toContain("Discard changes");

    title.value = "Arrival — Pending Preview";
    await userEvent(title, "input");
    const stalePreviewClick = userEvent(previewButton ?? null, "click");
    await vi.waitFor(() => expect(sidecarRequests).toBe(2));
    title.value = "Arrival — Latest Draft";
    await userEvent(title, "input");
    resolveStalePreview(
      new Response(
        wireJson({
          id: "stale-metadata-plan",
          digest: "b".repeat(64),
          expiresAt: Date.now() + 1_800_000,
          actions: [{ destinationRelativePath: "_Movies/Arrival.nfo" }],
          warnings: [],
        }),
        { status: 201 },
      ),
    );
    await stalePreviewClick;

    expect(screen.querySelector(".metadata-change-review")).toBeUndefined();
    expect(title.value).toBe("Arrival — Latest Draft");
  });

  it("inspects installed external and embedded subtitles with cue validation", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Movie.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
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
                : path.endsWith("/items/movie-1/metadata")
                  ? {
                      mediaType: "movie",
                      title: "Movie",
                      sources: ["filename"],
                    }
                  : path.endsWith("/items/movie-1/subtitles")
                    ? {
                        subtitles: [
                          {
                            source: "external",
                            itemId: "subtitle-1",
                            relativePath: "_Movies/Movie.en.forced.srt",
                            format: "srt",
                            language: "en",
                            isDefault: false,
                            isForced: true,
                            isHearingImpaired: false,
                            isPreviewable: true,
                          },
                          {
                            source: "embedded",
                            streamIndex: 2,
                            title: "English SDH",
                            format: "subrip",
                            language: "eng",
                            isDefault: true,
                            isForced: false,
                            isHearingImpaired: true,
                            isPreviewable: false,
                          },
                        ],
                        consumers: [
                          {
                            id: "jellyfin",
                            label: "Jellyfin",
                            available: true,
                            effect: "read-after-refresh",
                            canManageNatively: true,
                            portableWriteSupported: true,
                            message: "Managed natively",
                            nativeUrl: "https://videos.example.test",
                          },
                        ],
                      }
                    : path.endsWith(
                          "/items/movie-1/subtitles/installed/subtitle-1/content",
                        )
                      ? {
                          cues: [
                            {
                              index: 1,
                              startMs: 1000,
                              endMs: 2500,
                              text: "Come with me.",
                            },
                          ],
                          truncated: false,
                          validation: {
                            cueCount: 1,
                            issueCount: 0,
                            issues: [],
                          },
                        }
                      : { available: false, progress: {} };
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeTruthy(),
    );
    const subtitlesToggle = screen.querySelector(
      ".subtitles-accordion .source-accordion-summary",
    );
    await userEvent(subtitlesToggle ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Movie.en.forced.srt"),
    );
    expect(screen.textContent).toContain("Upload");
    expect(screen.textContent).toContain("OpenSubtitles");
    expect(screen.textContent).not.toContain("Cataloged video");
    expect(screen.textContent).toContain("English SDH");
    expect(screen.textContent).toContain("forced");
    expect(screen.textContent).toContain("SDH/CC");
    expect(screen.textContent).toContain("Manage in Jellyfin");
    const inspect = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Inspect cues",
    );
    await userEvent(inspect ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Come with me."),
    );
    expect(screen.textContent).toContain("1 cues · 0 issues");
  });

  it("previews and queues removing an item into the library tombstone", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Example Movie (2020).mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    let previewRequests = 0;
    let confirmRequests = 0;
    let resolveRemoval!: (response: Response) => void;
    const removalConfirmation = new Promise<Response>((resolve) => {
      resolveRemoval = resolve;
    });
    const confirmDiscard = vi.fn(() => false);
    vi.stubGlobal("confirm", confirmDiscard);
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
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
              : path.includes("/items?rootId=")
                ? { items }
                : path.endsWith("/items/movie-1/metadata")
                  ? {
                      mediaType: "movie",
                      title: "Example Movie",
                      year: 2020,
                      sources: ["filename"],
                    }
                  : undefined;
        if (payload !== undefined) {
          return new Response(wireJson(payload));
        }
        if (path.endsWith("/plans") && init?.method === "POST") {
          previewRequests += 1;
          return new Response(
            wireJson({
              id: "plan-tombstone",
              digest: "abc123",
              expiresAt: Date.now() + 1800000,
              actions: [
                {
                  kind: "move",
                  sourceRelativePath: "_Movies/Example Movie (2020).mkv",
                  destinationRelativePath:
                    "_Tombstone/_Movies/Example Movie (2020).mkv",
                },
              ],
              warnings: [],
            }),
            { status: 201 },
          );
        }
        if (/\/plans\/[^/]+\/confirm$/.test(path) && init?.method === "POST") {
          confirmRequests += 1;
          return removalConfirmation;
        }
        return new Response(wireJson({ available: false, progress: {} }));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
    const draftButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Create draft",
    );
    await userEvent(draftButton ?? null, "click");
    const title = screen.querySelector<HTMLInputElement>(
      ".editor-metadata-form .title-input input",
    );
    if (!title) throw new Error("metadata title input missing");
    title.value = "Example Movie — Unsaved";
    await userEvent(title, "input");

    const removeButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Remove from library",
    );
    await userEvent(removeButton ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Confirm removal"),
    );
    expect(previewRequests).toBe(1);
    expect(screen.textContent).toContain(
      "_Tombstone/_Movies/Example Movie (2020).mkv",
    );

    const confirmButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Confirm removal",
    );
    await userEvent(confirmButton ?? null, "click");

    expect(confirmDiscard).toHaveBeenCalledTimes(1);
    expect(confirmRequests).toBe(0);
    expect(screen.textContent).toContain("Discard changes");

    confirmDiscard.mockReturnValue(true);
    const confirmationClick = userEvent(confirmButton ?? null, "click");

    await vi.waitFor(() => expect(confirmRequests).toBe(1));
    title.value = "Example Movie — Newer Unsaved Edit";
    await userEvent(title, "input");
    resolveRemoval(
      new Response(wireJson({ id: "plan-tombstone", state: "queued" }), {
        status: 202,
      }),
    );
    await confirmationClick;
    expect(title.value).toBe("Example Movie — Newer Unsaved Edit");
    expect(screen.textContent).toContain("Discard changes");
    expect(screen.textContent).toContain("Newer draft edits remain unsaved");
  });

  it("compares a MusicBrainz release and adds only selected fields to the draft", async () => {
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
        return new Response(wireJson(payload));
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
    expect(screen.textContent).toContain("MusicBrainz");
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

    const compareButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Compare fields",
    );
    await userEvent(compareButton ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".metadata-match-workspace")).toBeDefined(),
    );
    expect(screen.textContent).toContain("Review MusicBrainz match");
    const genresToggle = screen.querySelector(
      'input[aria-label="Use Genres from MusicBrainz"]',
    ) as HTMLInputElement | null;
    expect(genresToggle?.checked).toBe(true);
    await userEvent(genresToggle, "click");
    const applyButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Add selected to draft",
    );
    await userEvent(applyButton ?? null, "click");

    await vi.waitFor(() =>
      expect(
        screen
          .querySelector(".editor-metadata-form .title-input input")
          ?.getAttribute("value"),
      ).toBe("Nevermind"),
    );
    expect(screen.querySelector(".metadata-toolbar")?.textContent).toContain(
      "Discard draft",
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
    const sectionTab = (label: string): Element | null =>
      Array.from(screen.querySelectorAll(".metadata-section-tab")).find(
        (element) => element.textContent?.trim() === label,
      ) ?? null;
    expect(fieldValue("Year")).toBe("1991");
    expect(fieldValue("Genres")).toBe("");
    await userEvent(sectionTab("Advanced"), "click");
    await vi.waitFor(() =>
      expect(
        screen.querySelector(".metadata-section-tab.active")?.textContent,
      ).toBe("Advanced"),
    );
    expect(fieldValue("Authors / artists")).toBe("Nirvana");
    expect(fieldValue("Publisher / studio")).toBe("DGC");
    expect(screen.textContent).toContain("People");
    expect(screen.textContent).toContain("Release & ratings");
    expect(
      fetchMock.mock.calls.some(
        ([callInput, callInit]) =>
          String(callInput).endsWith("/metadata/lookup") &&
          String(callInit?.body).includes('"mode":"auto"'),
      ),
    ).toBe(true);
  });

  it("compares a movie from the signed-in user's TMDB account before filling a reviewable draft", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Arrival.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path.endsWith("/status"))
          return new Response(
            wireJson({ mutationMode: "enabled", integrations: [] }),
          );
        if (path.endsWith("/session"))
          return new Response(
            wireJson({
              username: "dsaw",
              groups: ["users"],
              canEdit: true,
            }),
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
          return new Response(wireJson({ items }));
        if (path.endsWith("/items/movie-1/metadata"))
          return new Response(
            wireJson({
              mediaType: "movie",
              title: "Arrival",
              language: "en",
              sources: ["filename"],
              providerIds: { tvdb: "1234" },
            }),
          );
        if (
          path.endsWith("/provider-lookups/tmdb/search") &&
          init?.method === "POST"
        )
          return new Response(
            wireJson({
              provider: "tmdb",
              results: [
                {
                  mediaType: "movie",
                  tmdbId: 329865,
                  title: "Arrival",
                  year: 2016,
                  posterPath: "/arrival.jpg",
                  overview: "A linguist works with the military.",
                  voteAverage: 7.6,
                  voteCount: 18000,
                },
              ],
            }),
          );
        if (
          path.endsWith("/provider-lookups/tmdb/details") &&
          init?.method === "POST"
        )
          return new Response(
            wireJson({
              provider: "tmdb",
              details: {
                mediaType: "movie",
                tmdbId: 329865,
                title: "Arrival",
                overview: "A linguist works with the military.",
                year: 2016,
                runtimeMinutes: 116,
                voteAverage: 7.6,
                genres: ["Drama", "Science Fiction"],
                crew: [{ name: "Eric Heisserer", job: "Screenplay" }],
                externalIds: { imdbId: "tt2543164" },
              },
            }),
          );
        return new Response(wireJson({ available: false, progress: {} }));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".tmdb-panel")).toBeDefined(),
    );
    expect(screen.textContent).toContain("The Movie Database");
    expect(
      screen
        .querySelector(".tmdb-panel .metadata-source-setup-link")
        ?.getAttribute("href"),
    ).toBe("?view=accounts");

    await userEvent(
      screen.querySelector(".tmdb-panel .primary-button"),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("18,000 votes"),
    );
    const compareButton = Array.from(
      screen.querySelectorAll(".tmdb-panel button"),
    ).find((button) => button.textContent?.trim() === "Compare fields");
    await userEvent(compareButton ?? null, "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".metadata-match-workspace")).toBeDefined(),
    );
    expect(screen.textContent).toContain("Review TMDB match");
    expect(screen.textContent).toContain("A linguist works with the military.");
    const applyButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Add selected to draft",
    );
    await userEvent(applyButton ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain(
        "Added 7 TMDB fields to the draft. Review them before previewing",
      ),
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-facts")?.textContent).toContain(
        "TMDB ID",
      ),
    );
    expect(screen.querySelector(".editor-facts")?.textContent).toContain(
      "TVDB ID",
    );
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("/provider-lookups/tmdb/details"),
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("searches Open Library and adds selected book fields to the draft", async () => {
    const items = [
      {
        id: "book-1",
        rootId: "shared-books",
        relativePath: "Dune.epub",
        mediaKind: "book",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path.endsWith("/status"))
          return new Response(
            wireJson({ mutationMode: "enabled", integrations: [] }),
          );
        if (path.endsWith("/session"))
          return new Response(
            wireJson({
              username: "dsaw",
              groups: ["users"],
              canEdit: true,
            }),
          );
        if (path.endsWith("/roots"))
          return new Response(
            wireJson([
              {
                id: "shared-books",
                label: "Shared books",
                category: "books",
                scope: "shared",
                available: true,
              },
            ]),
          );
        if (path.includes("/items?rootId=shared-books"))
          return new Response(wireJson({ items }));
        if (path.endsWith("/items/book-1/metadata"))
          return new Response(
            wireJson({
              mediaType: "book",
              title: "Dune",
              authors: ["Frank Herbert"],
              language: "en",
              sources: ["embedded-epub"],
            }),
          );
        if (
          path.endsWith("/provider-lookups/open-library/search") &&
          init?.method === "POST"
        )
          return new Response(
            wireJson({
              provider: "open-library",
              results: [
                {
                  workId: "OL893415W",
                  editionId: "OL75313M",
                  title: "Dune",
                  authors: ["Frank Herbert"],
                  firstPublishYear: 1965,
                  publishYear: 1990,
                  editionCount: 312,
                  publishDate: "September 1990",
                  publishers: ["Ace Books"],
                  isbn10: "0441172717",
                  isbn13: "9780441172719",
                  languages: ["eng"],
                  subjects: ["Science fiction", "Dune (Imaginary place)"],
                  numberOfPages: 535,
                },
              ],
            }),
          );
        return new Response(wireJson({ available: false, progress: {} }));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-books" />);
    await vi.waitFor(() =>
      expect(screen.querySelector(".tree-row.file")).toBeDefined(),
    );
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".open-library-panel")).toBeDefined(),
    );
    expect(screen.textContent).toContain("Open Library");
    expect(screen.textContent).toContain("Free access");

    await userEvent(
      screen.querySelector(".open-library-panel .primary-button"),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("312 editions"),
    );
    expect(screen.textContent).toContain("Frank Herbert");
    expect(screen.textContent).toContain("Ace Books");

    const compareButton = Array.from(
      screen.querySelectorAll(".open-library-panel button"),
    ).find((button) => button.textContent?.trim() === "Compare fields");
    await userEvent(compareButton ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".metadata-match-workspace")).toBeDefined(),
    );
    expect(screen.textContent).toContain("Review Open Library match");
    expect(screen.textContent).toContain("Science fiction");

    const applyButton = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Add selected to draft",
    );
    await userEvent(applyButton ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Open Library fields to the draft"),
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-facts")?.textContent).toContain(
        "OPENLIBRARY ID",
      ),
    );
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("/provider-lookups/open-library/search"),
      expect.objectContaining({
        method: "POST",
        body: wireJson({ query: "Dune Frank Herbert" }),
      }),
    );
  });

  it("discards TMDB details that resolve after another item is selected", async () => {
    let resolveDetails!: (response: Response) => void;
    const pendingDetails = new Promise<Response>((resolve) => {
      resolveDetails = resolve;
    });
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Arrival.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
      {
        id: "movie-2",
        rootId: "shared-videos",
        relativePath: "_Movies/Blade Runner.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(
      async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path.endsWith("/status"))
          return new Response(
            wireJson({ mutationMode: "enabled", integrations: [] }),
          );
        if (path.endsWith("/session"))
          return new Response(
            wireJson({ username: "dsaw", groups: [], canEdit: true }),
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
          return new Response(wireJson({ items }));
        if (path.endsWith("/items/movie-1/metadata"))
          return new Response(
            wireJson({ mediaType: "movie", title: "Arrival" }),
          );
        if (path.endsWith("/items/movie-2/metadata"))
          return new Response(
            wireJson({ mediaType: "movie", title: "Blade Runner" }),
          );
        if (path.endsWith("/provider-lookups/tmdb/search"))
          return new Response(
            wireJson({
              provider: "tmdb",
              results: [
                {
                  mediaType: "movie",
                  tmdbId: 329865,
                  title: "Arrival",
                  year: 2016,
                },
              ],
            }),
          );
        if (
          path.endsWith("/provider-lookups/tmdb/details") &&
          init?.method === "POST"
        )
          return pendingDetails;
        return new Response(wireJson({ available: false, progress: {} }));
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    const files = screen.querySelectorAll(".tree-row.file");
    await userEvent(files[0], "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".tmdb-panel")).toBeDefined(),
    );
    await userEvent(
      screen.querySelector(".tmdb-panel .primary-button"),
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Arrival (2016)"),
    );
    const compareButton = Array.from(
      screen.querySelectorAll(".tmdb-panel button"),
    ).find((button) => button.textContent?.trim() === "Compare fields");
    const compareClick = userEvent(compareButton ?? null, "click");
    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([callInput]) =>
          String(callInput).endsWith("/provider-lookups/tmdb/details"),
        ),
      ).toBe(true),
    );

    await userEvent(files[1], "click");
    await vi.waitFor(() =>
      expect(
        screen
          .querySelector(".editor-metadata-form .title-input input")
          ?.getAttribute("value"),
      ).toBe("Blade Runner"),
    );
    resolveDetails(
      new Response(
        wireJson({
          provider: "tmdb",
          details: {
            mediaType: "movie",
            tmdbId: 329865,
            title: "Arrival",
            overview: "Stale details from the previous item.",
            year: 2016,
          },
        }),
      ),
    );
    await compareClick;

    expect(screen.querySelector(".metadata-match-workspace")).toBeUndefined();
    expect(screen.querySelector(".remote-artwork-preview")).toBeUndefined();
    expect(screen.textContent).not.toContain(
      "Stale details from the previous item.",
    );
  });

  it("offers play and metadata actions and reveals cover editing from the image", async () => {
    const items = [
      {
        id: "movie-1",
        rootId: "shared-videos",
        relativePath: "_Movies/Arrival.mkv",
        mediaKind: "video",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.endsWith("/items/movie-1/playback-targets")) {
        return new Response(
          wireJson({
            targets: [
              {
                id: "jellyfin",
                label: "Jellyfin",
                available: true,
                url: "https://jellyfin.example",
              },
            ],
          }),
        );
      }
      if (path.endsWith("/items/movie-1/metadata")) {
        return new Response(
          wireJson({
            mediaType: "movie",
            title: "Arrival",
            sources: ["filename"],
          }),
        );
      }
      return libraryFetchMock(items, true)(input);
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-videos" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(screen.querySelector(".item-quick-actions")).toBeDefined(),
    );
    const playLink = screen.querySelector<HTMLAnchorElement>(
      ".item-quick-actions a.quick-action-button.play",
    );
    expect(playLink?.getAttribute("href")).toBe("https://jellyfin.example");
    expect(playLink?.getAttribute("target")).toBe("_blank");
    expect(playLink?.textContent).toContain("Play in Jellyfin");

    await userEvent(screen.querySelector(".media-image.editable"), "click");
    expect(screen.textContent).toContain("Edit cover image");
    expect(screen.textContent).toContain("Replace cover art");
    await userEvent(
      screen.querySelector('[aria-label="Close cover image editor"]'),
      "click",
    );
    expect(screen.textContent).not.toContain("Edit cover image");

    expect(
      Array.from(screen.querySelectorAll("button")).some(
        (button) => button.textContent?.trim() === "Edit image",
      ),
    ).toBe(false);
    expect(
      Array.from(screen.querySelectorAll("button")).some(
        (button) => button.textContent?.trim() === "Edit title",
      ),
    ).toBe(false);

    await userEvent(
      Array.from(screen.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Metadata",
      ) ?? null,
      "click",
    );
    expect(
      screen.querySelector<HTMLInputElement>(
        ".editor-metadata-form .title-input input",
      )?.value,
    ).toBe("Arrival");
  });

  it("plays a music selection in a page mini player", async () => {
    const items = [
      {
        id: "track-1",
        rootId: "shared-music",
        relativePath: "_Music/Nirvana - Lithium.flac",
        mediaKind: "music",
        sizeBytes: 4096,
      },
    ];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.endsWith("/items/track-1/playback-targets")) {
        return new Response(
          wireJson({
            targets: [
              {
                id: "jellyfin",
                label: "Jellyfin",
                available: true,
                url: "https://jellyfin.example",
              },
            ],
          }),
        );
      }
      if (path.endsWith("/items/track-1/metadata")) {
        return new Response(
          wireJson({
            mediaType: "music",
            title: "Lithium",
            sources: ["filename"],
          }),
        );
      }
      return libraryFetchMock(items, true)(input);
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="library" initialRootId="shared-music" />);
    await userEvent(screen.querySelector(".tree-row.file"), "click");

    await vi.waitFor(() =>
      expect(
        Array.from(screen.querySelectorAll("button")).find(
          (button) => button.textContent?.trim() === "Play here",
        ),
      ).toBeDefined(),
    );
    expect(screen.querySelector(".subtitles-accordion")).toBeUndefined();
    await userEvent(
      Array.from(screen.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Play here",
      ) ?? null,
      "click",
    );
    await vi.waitFor(() =>
      expect(screen.querySelector(".mini-player")).toBeDefined(),
    );
    expect(screen.querySelector(".mini-player-info strong")?.textContent).toBe(
      "Lithium",
    );
    expect(screen.querySelector(".mini-player-info span")?.textContent).toBe(
      "Nirvana",
    );
    expect(
      screen.querySelector(".mini-player audio")?.getAttribute("src"),
    ).toBe("/api/v1/items/track-1/stream");

    await userEvent(
      screen.querySelector('[aria-label="Close music player"]'),
      "click",
    );
    expect(screen.querySelector(".mini-player")).toBeUndefined();
  });

  it("hides lookup and portable-metadata actions for a native-only podcast", async () => {
    const podcast = {
      id: "episode-1",
      rootId: "shared-podcasts",
      relativePath: "_Podcasts/Show/Episode 1.mp3",
      mediaKind: "podcast",
      sizeBytes: 2048,
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      const payload = path.endsWith("/status")
        ? { mutationMode: "enabled", integrations: [] }
        : path.endsWith("/session")
          ? { username: "dsaw", groups: ["users"], canEdit: true }
          : path.endsWith("/roots")
            ? [
                {
                  id: "shared-podcasts",
                  label: "Shared podcasts",
                  category: "podcasts",
                  scope: "shared",
                  available: true,
                },
              ]
            : path.endsWith("/items/episode-1/metadata")
              ? {
                  mediaType: "podcast",
                  mediaKind: "podcast",
                  title: "Episode 1",
                  sources: ["filename"],
                }
              : path.endsWith("/items/episode-1/playback-targets")
                ? { targets: [] }
                : path.includes("/items?rootId=")
                  ? { items: [podcast] }
                  : { available: false, progress: {} };
      return new Response(wireJson(payload));
    });
    vi.stubGlobal("fetch", fetchMock);

    const { render, screen, userEvent } = await createDOM();
    await render(
      <Root initialView="library" initialRootId="shared-podcasts" />,
    );
    const showToggle = Array.from(
      screen.querySelectorAll(".tree-row.folder .tree-toggle"),
    ).at(-1);
    await userEvent(showToggle ?? null, "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".tree-row.file")).toBeTruthy(),
    );
    await userEvent(screen.querySelector(".tree-row.file"), "click");
    await vi.waitFor(() =>
      expect(screen.querySelector(".editor-card")).toBeDefined(),
    );
    expect(screen.querySelector(".metadata-sources")).toBeUndefined();
    expect(screen.querySelector(".subtitles-accordion")).toBeUndefined();
    expect(
      Array.from(screen.querySelectorAll("button")).some(
        (button) => button.textContent?.trim() === "Explore metadata",
      ),
    ).toBe(false);
    expect(
      Array.from(screen.querySelectorAll("button")).some(
        (button) => button.textContent?.trim() === "Create draft",
      ),
    ).toBe(false);
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

describe("metadata change review", () => {
  it("offers safe alternative values from observed metadata sources", () => {
    expect(
      metadataSourceChoices(
        [
          {
            source: "filename",
            label: "Filename",
            fields: { title: "Current title", year: 2020 },
          },
          {
            source: "sidecar",
            label: "NFO sidecar",
            fields: {
              title: "Restored title",
              year: 2020,
              genres: ["Drama", "Mystery"],
              description: { unsafe: "not selectable" },
            },
          },
          {
            source: "invalid-app-snapshot",
            label: "Invalid app snapshot",
            fields: {
              authors: Array.from(
                { length: 33 },
                (_, index) => `Author ${index + 1}`,
              ).join(", "),
              genres: `Drama, ${"x".repeat(501)}`,
              premiereDate: "2026-99-99",
            },
          },
        ],
        { title: "Current title", year: "2020", genres: "Drama" },
      ),
    ).toEqual([
      {
        field: "title",
        label: "Title",
        options: [
          { source: "filename", label: "Filename", value: "Current title" },
          {
            source: "sidecar",
            label: "NFO sidecar",
            value: "Restored title",
          },
        ],
      },
      {
        field: "genres",
        label: "Genres",
        options: [
          {
            source: "sidecar",
            label: "NFO sidecar",
            value: "Drama, Mystery",
          },
        ],
      },
    ]);
  });

  it("reports only changed editable fields with readable before and after values", () => {
    expect(
      metadataFieldChanges(
        {
          title: "Arrival",
          year: "2016",
          genres: "Drama, Science Fiction",
          description: "A linguist investigates an arrival.",
          providerIds: "",
        },
        {
          title: "Arrival",
          year: "2016",
          genres: "Drama, Mystery",
          description: "",
          providerIds: "tmdb: 329865",
        },
      ),
    ).toEqual([
      {
        field: "genres",
        label: "Genres",
        before: "Drama, Science Fiction",
        after: "Drama, Mystery",
      },
      {
        field: "description",
        label: "Description",
        before: "A linguist investigates an arrival.",
        after: "Not set",
      },
      {
        field: "providerIds",
        label: "Provider IDs",
        before: "Not set",
        after: "tmdb: 329865",
      },
    ]);
  });
});

describe("Media Manager visual hierarchy", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("uses libraries as the landing page instead of rendering an overview", async () => {
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
        return new Response(wireJson(payload));
      }),
    );

    const { render, screen } = await createDOM();
    await render(<Root />);

    expect(screen.querySelector(".overview-carousels")).toBeUndefined();
    expect(screen.querySelector(".section-label")).toBeUndefined();
    expect(screen.querySelector(".stat-grid")).toBeUndefined();
    expect(screen.textContent).not.toContain("Available roots");
    expect(screen.textContent).not.toContain("Active conversions");
    expect(screen.textContent).not.toContain("Connected apps");
  });
});
