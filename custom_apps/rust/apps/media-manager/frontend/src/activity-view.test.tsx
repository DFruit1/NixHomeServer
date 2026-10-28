import { wireJson } from "./test-support/wire-fixtures";
// @vitest-environment node

import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import Root from "./root";

function baseFetch(
  handle: (path: string, init?: RequestInit) => Response | undefined,
) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = String(input);
    const handled = handle(path, init);
    if (handled) return handled;
    if (path.endsWith("/status"))
      return new Response(
        wireJson({ mutationMode: "enabled", integrations: [] }),
      );
    if (path.endsWith("/session"))
      return new Response(
        wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
      );
    if (path.endsWith("/roots")) return new Response(wireJson([]));
    return new Response(wireJson({ available: false, progress: {} }));
  });
}

describe("Media Manager activity queue", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("loads every item in a long plan without waiting for another poll", async () => {
    const ids = Array.from({ length: 12 }, (_, index) => `item-${index}`);
    const fetchMock = baseFetch((path) => {
      if (path.includes("/items/item-")) {
        const id = path.split("/").at(-1)!;
        return new Response(
          wireJson({
            id,
            rootId: "shared-videos",
            relativePath: `Films/${id}.mkv`,
            mediaKind: "video",
            sizeBytes: 1,
          }),
        );
      }
      if (path.includes("/plans"))
        return new Response(
          wireJson({
            scope: "all",
            canViewAll: true,
            mutationMode: "enabled",
            plans: [
              {
                id: "long-plan",
                ownerUsername: "dsaw",
                state: "completed",
                operationKind: "canonicalize_names",
                itemIds: ids,
                actionCount: 12,
                completedActionCount: 12,
                createdAt: "2026-09-24 09:00:00",
                expiresAt: 0,
              },
            ],
            requestId: "req",
          }),
        );
      return undefined;
    });
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);
    await vi.waitFor(async () => {
      await userEvent(screen, "click");
      expect(screen.textContent).toContain("Films/item-11.mkv");
    });
  });

  it("retries an item lookup after a transient server failure", async () => {
    let attempts = 0;
    const fetchMock = baseFetch((path) => {
      if (path.endsWith("/items/item-retry")) {
        attempts++;
        if (attempts === 1)
          return new Response(
            wireJson({ error: { message: "Temporary failure" } }),
            { status: 503 },
          );
        return new Response(
          wireJson({
            id: "item-retry",
            rootId: "shared-videos",
            relativePath: "Films/Recovered.mkv",
            mediaKind: "video",
            sizeBytes: 1,
          }),
        );
      }
      if (path.includes("/plans"))
        return new Response(
          wireJson({
            scope: "all",
            canViewAll: true,
            mutationMode: "enabled",
            plans: [
              {
                id: "retry-plan",
                ownerUsername: "dsaw",
                state: "completed",
                operationKind: "canonicalize_names",
                itemIds: ["item-retry"],
                actionCount: 1,
                completedActionCount: 1,
                createdAt: "2026-09-24 09:00:00",
                expiresAt: 0,
              },
            ],
            requestId: "req",
          }),
        );
      return undefined;
    });
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);
    await vi.waitFor(async () => {
      await userEvent(screen, "click");
      expect(screen.textContent).toContain("Item lookup failed; retrying");
    });
    const mine = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Mine",
    );
    await userEvent(mine ?? null, "click");
    await vi.waitFor(async () => {
      await userEvent(screen, "click");
      expect(screen.textContent).toContain("Recovered.mkv");
    });
    expect(attempts).toBe(2);
  });

  it("does not start another lookup batch while the previous scope is still loading", async () => {
    const ids = Array.from({ length: 12 }, (_, index) => `slow-${index}`);
    const pending: Array<(value: Response) => void> = [];
    let requests = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.includes("/items/slow-")) {
        requests++;
        return new Promise<Response>((resolve) => pending.push(resolve));
      }
      if (path.includes("/plans"))
        return new Response(
          wireJson({
            scope: "all",
            canViewAll: true,
            mutationMode: "enabled",
            plans: [
              {
                id: "slow-plan",
                ownerUsername: "dsaw",
                state: "completed",
                operationKind: "canonicalize_names",
                itemIds: ids,
                actionCount: 12,
                completedActionCount: 12,
                createdAt: "2026-09-24 09:00:00",
                expiresAt: 0,
              },
            ],
            requestId: "req",
          }),
        );
      if (path.endsWith("/status"))
        return new Response(
          wireJson({ mutationMode: "enabled", integrations: [] }),
        );
      if (path.endsWith("/session"))
        return new Response(
          wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
        );
      if (path.endsWith("/roots")) return new Response(wireJson([]));
      return new Response(wireJson({ available: false, progress: {} }));
    });
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);
    await vi.waitFor(() => expect(requests).toBe(8));
    const mine = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Mine",
    );
    await userEvent(mine ?? null, "click");
    expect(requests).toBe(8);
    for (const resolve of pending)
      resolve(
        new Response(wireJson({ error: { message: "temporary" } }), {
          status: 503,
        }),
      );
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(requests).toBe(8);
  });

  it("ignores a delayed plan response from the previous scope", async () => {
    let resolveMine!: (response: Response) => void;
    const mineResponse = new Promise<Response>(
      (resolve) => (resolveMine = resolve),
    );
    const plan = (id: string) => ({
      id,
      ownerUsername: "dsaw",
      state: "completed",
      operationKind:
        id === "mine-plan" ? "install_subtitle" : "canonicalize_names",
      itemIds: [],
      actionCount: 0,
      completedActionCount: 0,
      createdAt: "2026-09-24 09:00:00",
      expiresAt: 0,
    });
    const response = (id: string) =>
      new Response(
        wireJson({
          scope: "all",
          canViewAll: true,
          mutationMode: "enabled",
          plans: [plan(id)],
          requestId: "req",
        }),
      );
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path.endsWith("/plans")) return mineResponse;
      if (path.includes("/plans?scope=all")) return response("all-plan");
      if (path.endsWith("/status"))
        return new Response(
          wireJson({ mutationMode: "enabled", integrations: [] }),
        );
      if (path.endsWith("/session"))
        return new Response(
          wireJson({ username: "dsaw", groups: ["users"], canEdit: true }),
        );
      if (path.endsWith("/roots")) return new Response(wireJson([]));
      return new Response(wireJson({ available: false, progress: {} }));
    });
    vi.stubGlobal("fetch", fetchMock);
    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);
    await vi.waitFor(() => expect(screen.textContent).toContain("Rename"));
    const button = (label: string) =>
      Array.from(screen.querySelectorAll(".activity-scope button")).find(
        (item) => item.textContent?.trim() === label,
      );
    await userEvent(button("Mine") ?? null, "click");
    await userEvent(button("Everyone") ?? null, "click");
    resolveMine(response("mine-plan"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.querySelector('button[data-filter="all"]')).toBeTruthy();
    expect(screen.textContent).toContain("Rename");
    expect(screen.textContent).not.toContain("Install subtitle");
    expect(
      fetchMock.mock.calls.filter(([input]) =>
        String(input).includes("/plans?scope=all"),
      ),
    ).toHaveLength(2);
  });

  it("lists plan states and retries a failed plan", async () => {
    const plans = [
      {
        id: "plan-failed",
        ownerUsername: "dsaw",
        state: "failed",
        operationKind: "canonicalize_names",
        itemIds: ["item-1"],
        actionCount: 1,
        completedActionCount: 0,
        createdAt: "2026-09-24 09:00:00",
        expiresAt: 0,
        error: "rename target exists",
      },
      {
        id: "plan-queued",
        ownerUsername: "dsaw",
        state: "queued",
        operationKind: "install_subtitle",
        itemIds: ["item-2"],
        actionCount: 1,
        completedActionCount: 0,
        createdAt: "2026-09-24 08:00:00",
        expiresAt: 0,
        error: null,
      },
    ];
    const fetchMock = baseFetch((path, init) => {
      if (path.endsWith("/items/item-1"))
        return new Response(
          wireJson({
            id: "item-1",
            rootId: "shared-videos",
            relativePath: "Films/Arrival.mkv",
            mediaKind: "video",
            sizeBytes: 1,
          }),
        );
      if (
        path.endsWith("/plans/plan-failed/retry") &&
        init?.method === "POST"
      ) {
        plans[0] = { ...plans[0], state: "queued", error: null };
        return new Response(
          wireJson({ id: "plan-failed", state: "queued", requestId: "req" }),
        );
      }
      if (path.includes("/plans"))
        return new Response(
          wireJson({
            scope: "all",
            canViewAll: true,
            mutationMode: "enabled",
            plans,
            requestId: "req",
          }),
        );
      return undefined;
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal(
      "confirm",
      vi.fn(() => true),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);

    await vi.waitFor(() => expect(screen.textContent).toContain("Rename"));
    expect(screen.textContent).toContain("Failed");
    expect(screen.textContent).toContain("Install subtitle");
    expect(screen.textContent).toContain("rename target exists");
    await vi.waitFor(() => expect(screen.textContent).toContain("Arrival.mkv"));
    const failedFilter = screen.querySelector('button[data-filter="failed"]');
    expect(failedFilter).toBeTruthy();
    await userEvent(failedFilter, "click");
    expect(screen.textContent).not.toContain("Install subtitle");
    await userEvent(screen.querySelector('button[data-filter="all"]'), "click");
    expect(screen.textContent).toContain("Install subtitle");

    const retry = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Retry",
    );
    expect(retry, "retry button").toBeDefined();
    await userEvent(retry ?? null, "click");

    await vi.waitFor(() => {
      const retried = fetchMock.mock.calls.some(
        ([input, init]) =>
          String(input).endsWith("/plans/plan-failed/retry") &&
          (init as RequestInit)?.method === "POST",
      );
      expect(retried).toBe(true);
    });
  });

  it("cancels a previewed plan through the abandon endpoint", async () => {
    const fetchMock = baseFetch((path, init) => {
      if (
        path.endsWith("/plans/plan-preview/abandon") &&
        init?.method === "POST"
      )
        return new Response(
          wireJson({ id: "plan-preview", state: "rejected", requestId: "req" }),
        );
      if (path.includes("/plans"))
        return new Response(
          wireJson({
            scope: "all",
            canViewAll: true,
            mutationMode: "enabled",
            plans: [
              {
                id: "plan-preview",
                ownerUsername: "dsaw",
                state: "previewed",
                operationKind: "install_artwork",
                itemIds: ["item-9"],
                actionCount: 1,
                completedActionCount: 0,
                createdAt: "2026-09-24 09:00:00",
                expiresAt: 0,
                error: null,
              },
            ],
            requestId: "req",
          }),
        );
      return undefined;
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal(
      "confirm",
      vi.fn(() => true),
    );

    const { render, screen, userEvent } = await createDOM();
    await render(<Root initialView="activity" />);

    await vi.waitFor(() =>
      expect(screen.textContent).toContain("Awaiting confirmation"),
    );
    const cancel = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Cancel",
    );
    expect(cancel, "cancel button").toBeDefined();
    await userEvent(cancel ?? null, "click");

    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(
          ([input, init]) =>
            String(input).endsWith("/plans/plan-preview/abandon") &&
            (init as RequestInit)?.method === "POST",
        ),
      ).toBe(true),
    );
  });
});
