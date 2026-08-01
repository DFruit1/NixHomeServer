import { describe, expect, it, vi } from "vitest";
import { api, ApiError } from "./api";

describe("api", () => {
  it("returns parsed JSON for successful requests", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () => new Response(JSON.stringify({ service: "media-manager" })),
      ),
    );

    await expect(api<{ service: string }>("/status")).resolves.toEqual({
      service: "media-manager",
    });
  });

  it("preserves the stable server error code and request ID", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              error: {
                code: "editor_group_required",
                message: "Editors only.",
                requestId: "request-1",
              },
            }),
            { status: 403 },
          ),
      ),
    );

    const error = await api("/scans", { method: "POST" }).catch(
      (value: unknown) => value,
    );
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({
      code: "editor_group_required",
      requestId: "request-1",
    });
  });
});
