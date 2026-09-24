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
