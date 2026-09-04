// @vitest-environment node

import { $ } from "@builder.io/qwik";
import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, expect, it, vi } from "vitest";
import { OpenLibraryPanel } from "./open-library-panel";

afterEach(() => vi.unstubAllGlobals());

it("selects an edition and stages its cover through the confirmed artwork workflow", async () => {
  const fetchMock = vi.fn(
    async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      if (path.includes("/works/OL893415W/editions")) {
        const nextPage = path.includes("offset=12");
        return new Response(
          JSON.stringify({
            provider: "open-library",
            workId: "OL893415W",
            offset: 0,
            limit: 12,
            total: 13,
            hasMore: !nextPage,
            results: [
              {
                editionId: nextPage ? "OL2M" : "OL75313M",
                title: nextPage
                  ? "Dune: illustrated edition"
                  : "Dune: anniversary edition",
                publishDate: "September 1990",
                publishYear: 1990,
                publishers: ["Ace Books"],
                isbn13: "9780441172719",
                languages: ["eng"],
                numberOfPages: 535,
                coverId: 8231856,
              },
            ],
          }),
        );
      }
      if (path.endsWith("/provider-lookups/open-library/covers/8231856")) {
        return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), {
          headers: { "content-type": "image/png" },
        });
      }
      if (
        path.includes("/items/book-1/image/replacement?format=png") &&
        init?.method === "POST"
      ) {
        return new Response(
          JSON.stringify({
            id: "plan-cover",
            digest: "cover-digest",
            actions: [
              {
                kind: "install_artwork",
                destinationRelativePath: "Author/Dune/cover.png",
              },
            ],
            warnings: ["A new cover image will be installed."],
          }),
          { status: 201 },
        );
      }
      if (path.endsWith("/plans/plan-cover/confirm")) {
        return new Response(JSON.stringify({ state: "queued" }));
      }
      throw new Error(`unexpected request: ${path}`);
    },
  );
  vi.stubGlobal("fetch", fetchMock);
  const { render, screen, userEvent } = await createDOM();

  await render(
    <OpenLibraryPanel
      itemId="book-1"
      mutationMode="enabled"
      query="Dune"
      fallbackQuery=""
      candidates={[
        {
          workId: "OL893415W",
          title: "Dune",
          authors: ["Frank Herbert"],
          editionCount: 312,
          publishers: [],
          languages: [],
          subjects: ["Science fiction"],
          coverId: 8231856,
        },
      ]}
      loading={false}
      error=""
      canEdit={true}
      onQueryInput$={$(() => undefined)}
      onSearch$={$(() => undefined)}
      onCompare$={$(() => undefined)}
    />,
  );

  const viewEditions = Array.from(screen.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === "View editions",
  );
  await userEvent(viewEditions ?? null, "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Dune: anniversary edition"),
  );
  const loadMore = Array.from(screen.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === "Load more editions",
  );
  await userEvent(loadMore ?? null, "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Dune: illustrated edition"),
  );
  expect(fetchMock).toHaveBeenCalledWith(
    expect.stringContaining("offset=12"),
    expect.anything(),
  );

  const previewCover = Array.from(screen.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === "Preview cover",
  );
  await userEvent(previewCover ?? null, "click");
  expect(screen.querySelector(".open-library-cover-preview img")).toBeDefined();

  const prepare = Array.from(screen.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === "Prepare cover change",
  );
  await userEvent(prepare ?? null, "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("Confirm cover change"),
  );

  const confirm = Array.from(screen.querySelectorAll("button")).find(
    (button) => button.textContent?.trim() === "Confirm cover change",
  );
  await userEvent(confirm ?? null, "click");
  await vi.waitFor(() =>
    expect(screen.textContent).toContain("added to the mutation queue"),
  );
  expect(fetchMock).toHaveBeenCalledWith(
    "/api/v1/plans/plan-cover/confirm",
    expect.objectContaining({
      method: "POST",
      headers: expect.any(Headers),
    }),
  );
});
