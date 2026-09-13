import { describe, expect, it, vi } from "vitest";
import { api, ApiError } from "./api";

describe("api", () => {
  it("returns parsed JSON for successful requests", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              schemaVersion: 1,
              service: "media-manager",
              mutationMode: "enabled",
              integrations: [],
              mediaKinds: [],
            }),
          ),
      ),
    );

    await expect(api<{ service: string }>("/status")).resolves.toEqual({
      schemaVersion: 1,
      service: "media-manager",
      mutationMode: "enabled",
      integrations: [],
      mediaKinds: [],
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

describe("API contract failures", () => {
  it.each([
    "not json",
    "null",
    "{}",
    JSON.stringify({ username: 42, groups: [], canEdit: false }),
  ])("rejects malformed successful session responses: %s", async (body) => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(body)),
    );
    await expect(api("/session")).rejects.toMatchObject({
      code: "invalid_response",
    });
  });
  it("accepts a bodyless successful delete", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(null, { status: 204 })),
    );
    await expect(
      api("/provider-accounts/tmdb", { method: "DELETE" }),
    ).resolves.toBeUndefined();
  });
});

describe("response contract selection", () => {
  it("rejects undocumented successful responses", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("{}")),
    );
    await expect(api("/unknown-route")).rejects.toMatchObject({
      code: "invalid_response",
    });
    await expect(
      api("/plans/p/confirm", { method: "POST" }),
    ).rejects.toMatchObject({ code: "invalid_response" });
  });
  it("validates nested fields on templated paths with query strings", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              provider: "opensubtitles",
              fileId: 1,
              requestId: "r1",
              truncated: false,
              cues: [
                { index: 1, startMs: "invalid", endMs: 2000, text: "Hello" },
              ],
            }),
          ),
      ),
    );
    await expect(
      api("/items/video/subtitles/provider/1/content?preview=true"),
    ).rejects.toMatchObject({ code: "invalid_response" });
  });
});

it("rejects an undocumented bodyless success", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(null, { status: 204 })),
  );
  await expect(api("/session")).rejects.toMatchObject({
    code: "invalid_response",
  });
});
