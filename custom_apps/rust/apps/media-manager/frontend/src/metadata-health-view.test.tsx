import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, expect, it, vi } from "vitest";
import { MetadataHealthView } from "./metadata-health-view";

afterEach(() => vi.unstubAllGlobals());

it("does not append a stale page after selecting another library", async () => {
  let resolveNextPage!: (response: Response) => void;
  const nextPage = new Promise<Response>((resolve) => {
    resolveNextPage = resolve;
  });
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.includes("cursor=next-video-page")) return nextPage;
      if (path.includes("rootId=shared-videos")) {
        return healthResponse("video-item", "Video issue", "next-video-page");
      }
      return healthResponse("music-item", "Track needs an artist");
    }),
  );

  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[
        { id: "shared-videos", label: "Shared videos" },
        { id: "shared-music", label: "Shared music" },
      ]}
      initialRootId="shared-videos"
    />,
  );
  await vi.waitFor(() => expect(screen.textContent).toContain("Video issue"));
  await new Promise((resolve) => setTimeout(resolve, 0));

  const select = screen.querySelector("select");
  if (!select) throw new Error("missing select");
  (select as HTMLSelectElement).value = "shared-music";
  await userEvent(select, "change");
  await vi.waitFor(async () => {
    // Flush the test platform after a non-blocking resource update.
    await userEvent(screen, "click");
    expect(screen.textContent).toContain("Track needs an artist");
  });

  resolveNextPage(healthResponse("old-video-item", "Old video response"));
  await new Promise((resolve) => setTimeout(resolve, 0));

  expect(screen.textContent).toContain("Track needs an artist");
  expect(screen.textContent).not.toContain("Old video response");
});

it("shows a retryable error without describing a failed page as healthy", async () => {
  let attempts = 0;
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      attempts += 1;
      if (attempts === 1) {
        return new Response(
          wireJson({
            error: {
              code: "scan_failed",
              message: "The library could not be inspected.",
              requestId: "request-1",
            },
          }),
          { status: 502 },
        );
      }
      return healthResponse("music-item", "Recovered issue");
    }),
  );

  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[{ id: "shared-music", label: "Shared music" }]}
    />,
  );
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("The library could not be inspected."),
  );
  expect(screen.textContent).not.toContain("No metadata issues");
  expect(screen.textContent).toContain("incomplete");

  await userEvent(screen.querySelector(".health-retry"), "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Recovered issue"),
  );
});

it("inspects every library and every page by default and shows source values", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.includes("rootId=videos") && !path.includes("cursor="))
      return healthResponse("video-1", "Title differs", "next");
    const response = healthResponse(
      path.includes("cursor=") ? "video-2" : "music-1",
      "Title differs",
    );
    const payload = await response.json();
    payload.results[0].title = "Current title";
    payload.results[0].health[0] = {
      code: "conflicting-title",
      severity: "warning",
      field: "title",
      title: "Title differs",
      message: "Compare sources",
      sources: ["sidecar", "embedded"],
      currentValue: "Current title",
      currentSources: ["Sidecar"],
      proposedValues: [{ value: "Proposed title", sources: ["Embedded tags"] }],
    };
    return new Response(wireJson(payload));
  });
  vi.stubGlobal("fetch", fetchMock);
  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[
        { id: "videos", label: "Videos" },
        { id: "music", label: "Music" },
      ]}
    />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.querySelectorAll(".health-result")).toHaveLength(3);
  });
  expect(screen.textContent).toContain("All libraries");
  expect(screen.textContent).toContain("Current title");
  expect(screen.textContent).toContain("Proposed title");
  expect(screen.textContent).toContain("Embedded tags");
  expect(
    fetchMock.mock.calls.some(([path]) => String(path).includes("cursor=next")),
  ).toBe(true);
});

it("preserves issues from other libraries when one library fails", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) =>
      String(input).includes("rootId=broken")
        ? new Response(
            wireJson({ error: { message: "Library unavailable" } }),
            { status: 502 },
          )
        : healthResponse("good-item", "Useful issue"),
    ),
  );
  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[
        { id: "good", label: "Good" },
        { id: "broken", label: "Broken" },
      ]}
    />,
  );
  await vi.waitFor(() => expect(screen.textContent).toContain("incomplete"));
  expect(screen.textContent).toContain("Useful issue");
  expect(screen.textContent).toContain("Library unavailable");
});

it("rejects repeated pages before duplicating their issues", async () => {
  const fetchMock = vi.fn(async (_input: RequestInfo | URL) =>
    healthResponse("same-item", "Repeated issue", "same-cursor"),
  );
  vi.stubGlobal("fetch", fetchMock);
  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView roots={[{ id: "videos", label: "Videos" }]} />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.textContent).toContain("repeated page");
  });
  expect(screen.textContent).toContain("incomplete");
  expect(screen.querySelectorAll(".health-result")).toHaveLength(1);
  const issuePages = fetchMock.mock.calls.filter(([path]) =>
    String(path).includes("/metadata/issues"),
  );
  expect(issuePages).toHaveLength(2);
});

it("groups audio files of one album into a single warning", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      const first = await healthResponse("lawson-01", "Track ordering");
      const payload = await first.json();
      payload.results = [
        {
          itemId: "lawson-01",
          rootId: "audiobooks",
          relativePath: "Lawson/01_lawson.mp3",
          mediaKind: "audiobook",
          albumGroup: "Lawson",
          health: [
            {
              code: "missing-track-numbers",
              severity: "info",
              title: "Some files have no track number",
              message: "Confirm filename ordering.",
              sources: ["embedded-audio-tags"],
            },
          ],
        },
        {
          itemId: "lawson-02",
          rootId: "audiobooks",
          relativePath: "Lawson/02_lawson.mp3",
          mediaKind: "audiobook",
          albumGroup: "Lawson",
          health: [
            {
              code: "missing-track-numbers",
              severity: "info",
              title: "Some files have no track number",
              message: "Confirm filename ordering.",
              sources: ["embedded-audio-tags"],
            },
          ],
        },
      ];
      payload.inspectedItems = 2;
      payload.issueCount = 2;
      return new Response(wireJson(payload));
    }),
  );
  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView roots={[{ id: "audiobooks", label: "Audiobooks" }]} />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.querySelectorAll(".health-result")).toHaveLength(1);
  });
  const issues = screen.querySelectorAll(".health-result-issue");
  expect(issues).toHaveLength(1);
  expect(issues[0].textContent).toContain("Some files have no track number");
  expect(issues[0].textContent).toContain("Affects 2 files");
  expect(issues[0].textContent).toContain("01_lawson.mp3");
  expect(issues[0].textContent).toContain("02_lawson.mp3");
  expect(screen.textContent).toContain("2 files");
  expect(screen.textContent).toContain("Lawson/01_lawson.mp3");
  expect(screen.textContent).toContain("Lawson/02_lawson.mp3");
});

it("keeps distinct album issue values as separate entries", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      const response = await healthResponse("lawson-01", "Title differs");
      const payload = await response.json();
      payload.results = ["01", "02"].map((track) => ({
        itemId: `lawson-${track}`,
        rootId: "audiobooks",
        relativePath: `Lawson/${track}_lawson.mp3`,
        mediaKind: "audiobook",
        albumGroup: "Lawson",
        health: [
          {
            code: "conflicting-title",
            severity: "warning",
            field: "title",
            title: "Title differs",
            message: "Compare sources",
            sources: ["sidecar", "embedded"],
            currentValue: `Current ${track}`,
            currentSources: ["Sidecar"],
            proposedValues: [
              { value: `Proposed ${track}`, sources: ["Embedded tags"] },
            ],
          },
        ],
      }));
      payload.inspectedItems = 2;
      payload.issueCount = 2;
      return new Response(wireJson(payload));
    }),
  );
  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView roots={[{ id: "audiobooks", label: "Audiobooks" }]} />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.querySelectorAll(".health-result-issue")).toHaveLength(2);
  });
  expect(screen.textContent).toContain("Current 01");
  expect(screen.textContent).toContain("Proposed 02");
  expect(screen.querySelector(".health-provenance")?.textContent).toContain(
    "The current value comes from “Sidecar” and differs from it, so confirm which one matches the file in Review metadata.",
  );
});

it("names the recommended source for a missing field and lists the alternatives", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.includes("/provider-accounts"))
      return new Response(wireJson(providerCatalog(OPEN_LIBRARY, AUDNEXUS)));
    const response = healthResponse(
      "lawson-01",
      "Author or creator is missing",
    );
    const payload = await response.json();
    payload.results[0].mediaKind = "audiobook";
    payload.results[0].relativePath = "Lawson/01_lawson.mp3";
    payload.results[0].health[0] = {
      code: "missing-authors",
      severity: "warning",
      field: "authors",
      title: "Author or creator is missing",
      message:
        "Add a portable creator so the item remains identifiable outside one app.",
      sources: ["filename"],
      currentValue: null,
      proposedValues: [
        { value: "Grantlee Kieza", sources: ["Embedded audio tags"] },
      ],
    };
    return new Response(wireJson(payload));
  });
  vi.stubGlobal("fetch", fetchMock);

  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[{ id: "audiobooks", label: "Shared audiobooks" }]}
      canEdit
    />,
  );

  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.textContent).toContain("Grantlee Kieza");
  });

  expect(screen.querySelector(".health-lookup-note")).toBeFalsy();
  expect(screen.querySelector(".health-candidate small")).toBeFalsy();
  expect(screen.querySelector(".health-provenance")?.textContent).toBe(
    "The proposed value comes from “Embedded audio tags”.",
  );
  expect(screen.querySelector(".health-unset")?.textContent).toBe("Not set");

  const header = screen.querySelector(".health-result header");
  expect(header).toBeTruthy();
  expect(header?.querySelector("p")).toBeFalsy();
  const heading = header?.querySelector("h3");
  expect(heading?.className).toContain("health-result-title-file");
  expect(heading?.textContent).toBe("01_lawson.mp3");
  expect(
    header?.querySelector(".health-result-kind")?.getAttribute("aria-label"),
  ).toBe("Audiobook");
  expect(
    screen.querySelector(".health-result-kind")?.getAttribute("role"),
  ).toBe("img");

  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.textContent).toContain("Find from External Providers");
  });

  await userEvent(screen.querySelector(".health-source-trigger"), "click");
  await vi.waitFor(() =>
    expect(
      screen.querySelector('[role="dialog"] .health-lookup-note'),
    ).toBeTruthy(),
  );
  expect(
    screen
      .querySelector('[role="dialog"] .health-lookup-note')
      ?.textContent?.replace(/\s+/g, " "),
  ).toBe(
    "Online selections are comparison aids. Use Review metadata to make an edit.",
  );
  const dialog = screen.querySelector('[role="dialog"]');
  expect(dialog?.textContent).toContain("Find from External Providers");
  expect(dialog?.textContent).toContain("Author or creator is missing");
  expect(dialog?.textContent).toContain("Open Library");
  expect(dialog?.textContent).toContain("No setup needed");
  expect(dialog?.textContent).toContain("Audnexus");
  expect(dialog?.textContent).toContain("Coming soon");
  const documentation = screen.querySelector(
    '.health-source-links a[href="https://api.audnex.us/"]',
  );
  expect(documentation).toBeTruthy();
  await userEvent(
    screen.querySelector('[role="dialog"] .dialog-close'),
    "click",
  );
  await vi.waitFor(() =>
    expect(screen.querySelector('[role="dialog"]')).toBeFalsy(),
  );
});

it("explains conflicting proposals in prose beside the compared values", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      const response = healthResponse("lawson-01", "Title differs");
      const payload = await response.json();
      payload.results[0].health[0] = {
        code: "conflicting-title",
        severity: "warning",
        field: "title",
        title: "Title differs between sources",
        message:
          "Compare the source values and choose which layer should be authoritative.",
        sources: ["filename", "sidecar"],
        currentValue: null,
        currentSources: [],
        proposedValues: [
          { value: "Lawson: A Novel", sources: ["Embedded audio tags"] },
          { value: "Lawson (Unabridged)", sources: ["Sidecar"] },
        ],
      };
      return new Response(wireJson(payload));
    }),
  );

  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView roots={[{ id: "audiobooks", label: "Audiobooks" }]} />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.querySelectorAll(".health-provenance")).toHaveLength(1);
  });

  expect(screen.querySelector(".health-provenance")?.textContent).toBe(
    "These proposed values come from “Embedded audio tags” and “Sidecar”. " +
      "The sources disagree on this field, so check the file in Review " +
      "metadata before choosing one.",
  );
  expect(screen.querySelectorAll(".health-unset")).toHaveLength(1);
  expect(screen.querySelector(".health-value-text")?.textContent).toBe(
    "Not set",
  );
});

it("queues a metadata change when a proposed value is clicked", async () => {
  const fetchMock = vi.fn(
    async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      if (path.includes("/provider-accounts"))
        return new Response(wireJson(providerCatalog(OPEN_LIBRARY)));
      if (path.endsWith("/metadata"))
        return new Response(
          wireJson({
            mediaType: "audiobook",
            title: "Lawson",
            authors: [],
            narrators: [],
            genres: [],
            writers: [],
            providerIds: {},
            sources: ["sidecar"],
          }),
        );
      if (path.endsWith("/metadata/sidecar"))
        return new Response(
          wireJson({
            id: "health-plan",
            digest: "digest-1",
            expiresAt: 0,
            actions: [],
          }),
          { status: 201 },
        );
      if (path.includes("/plans/health-plan/confirm"))
        return new Response(wireJson({ id: "health-plan", state: "queued" }), {
          status: 202,
        });
      const response = await healthResponse(
        "lawson-01",
        "Author or creator is missing",
      );
      const payload = await response.json();
      payload.results[0].mediaKind = "audiobook";
      payload.results[0].health[0] = {
        code: "missing-authors",
        severity: "warning",
        field: "authors",
        title: "Author or creator is missing",
        message: "Add a portable creator so the item remains identifiable.",
        sources: ["filename"],
        currentValue: null,
        proposedValues: [
          { value: "Grantlee Kieza", sources: ["Embedded audio tags"] },
        ],
      };
      return new Response(wireJson(payload));
    },
  );
  vi.stubGlobal("fetch", fetchMock);

  const { render, screen, userEvent } = await createDOM();
  await render(
    <MetadataHealthView
      roots={[{ id: "audiobooks", label: "Audiobooks" }]}
      canEdit
    />,
  );
  await vi.waitFor(async () => {
    await userEvent(screen, "click");
    expect(screen.textContent).toContain("Grantlee Kieza");
  });

  const proposedButton = Array.from(
    screen.querySelectorAll(".health-value-set"),
  ).find((button) => button.textContent === "Grantlee Kieza");
  expect(proposedButton).toBeTruthy();
  await userEvent(proposedButton!, "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain(
      "See Activity to revisit the decision.",
    ),
  );

  const sidecarCall = fetchMock.mock.calls.find(
    ([path, init]) =>
      String(path).endsWith("/metadata/sidecar") && init?.method === "POST",
  );
  expect(sidecarCall).toBeTruthy();
  expect(JSON.parse(String(sidecarCall![1]?.body))).toMatchObject({
    title: "Lawson",
    authors: ["Grantlee Kieza"],
  });
  const confirmCall = fetchMock.mock.calls.find(
    ([path, init]) =>
      String(path).includes("/plans/health-plan/confirm") &&
      init?.method === "POST",
  );
  expect(confirmCall).toBeTruthy();
  const confirmInit = confirmCall![1];
  expect(confirmInit?.method).toBe("POST");
  expect(new Headers(confirmInit?.headers).get("if-match")).toBe('"digest-1"');
});

const OPEN_LIBRARY = {
  id: "open-library",
  name: "Open Library",
  mediaDomains: ["books", "audiobooks"],
  setupKind: "public",
  implementationStatus: "active",
  canConfigure: false,
  canTest: false,
  capabilities: [
    "search",
    "isbn",
    "editions",
    "covers",
    "bibliographic-metadata",
  ],
  credentialFields: [],
  setupUrl: "https://openlibrary.org/",
  documentationUrl: "https://openlibrary.org/developers/api",
  notes: "Public book search by title or ISBN.",
  account: { state: "notRequired" },
};

const AUDNEXUS = {
  id: "audnexus",
  name: "Audnexus",
  mediaDomains: ["audiobooks"],
  setupKind: "public",
  implementationStatus: "planned",
  canConfigure: false,
  canTest: false,
  capabilities: ["audiobook-search", "authors", "narrators", "series"],
  credentialFields: [],
  setupUrl: "https://audnex.us/",
  documentationUrl: "https://api.audnex.us/",
  notes: "Audiobook search with authors and narrators.",
  account: { state: "notConfigured" },
};

function providerCatalog(...providers: object[]): unknown {
  return {
    schemaVersion: 1,
    recoveryAdvice: "Keep the recovery copy in a password manager.",
    requestId: "request-1",
    providers,
  };
}

function healthResponse(
  itemId: string,
  title: string,
  nextCursor: string | null = null,
): Response {
  return new Response(
    wireJson({
      rootId: "root",
      inspectedItems: 1,
      issueCount: 1,
      severityCounts: { error: 0, warning: 1, info: 0 },
      nextCursor,
      results: [
        {
          itemId,
          rootId: "root",
          relativePath: `${itemId}.mp3`,
          mediaKind: "music",
          health: [
            {
              code: "missing-authors",
              severity: "warning",
              title,
              message: "Add portable creator metadata.",
              sources: ["filename"],
            },
          ],
        },
      ],
    }),
  );
}
