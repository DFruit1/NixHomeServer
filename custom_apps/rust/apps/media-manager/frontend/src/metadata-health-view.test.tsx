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
  const fetchMock = vi.fn(async () =>
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
  expect(fetchMock).toHaveBeenCalledTimes(2);
});

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
