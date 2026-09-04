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
  const loadMoreClick = userEvent(
    screen.querySelector(".health-load-more"),
    "click",
  );
  await new Promise((resolve) => setTimeout(resolve, 0));

  const select = screen.querySelector("select");
  if (!select) throw new Error("missing select");
  (select as HTMLSelectElement).value = "shared-music";
  await userEvent(select, "change");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Track needs an artist"),
  );

  resolveNextPage(healthResponse("old-video-item", "Old video response"));
  await loadMoreClick;
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
          JSON.stringify({
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
  expect(screen.textContent).not.toContain("0 issues across");

  await userEvent(screen.querySelector(".health-retry"), "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Recovered issue"),
  );
});

function healthResponse(
  itemId: string,
  title: string,
  nextCursor: string | null = null,
): Response {
  return new Response(
    JSON.stringify({
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
