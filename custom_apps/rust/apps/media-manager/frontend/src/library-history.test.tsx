// @vitest-environment node
import { createDOM } from "@builder.io/qwik/testing";
import { afterEach, expect, it, vi } from "vitest";
import Root from "./root";
import { wireJson } from "./test-support/wire-fixtures";

const handlers = vi.hoisted(() => new Map<string, () => Promise<void>>());
vi.mock("@builder.io/qwik", async (importOriginal) => {
  const qwik = await importOriginal<typeof import("@builder.io/qwik")>();
  return {
    ...qwik,
    useOnWindow: (...[event, handler]: Parameters<typeof qwik.useOnWindow>) => {
      if (handler) {
        for (const name of Array.isArray(event) ? event : [event]) {
          handlers.set(name, () =>
            Promise.resolve(handler(new Event(name), {} as Element)),
          );
        }
      }
      qwik.useOnWindow(event, handler);
    },
  };
});

afterEach(() => {
  handlers.clear();
  vi.unstubAllGlobals();
});

it("fetches an unloaded history item without overwriting a newer navigation", async () => {
  let resolveOlder!: (response: Response) => void;
  const older = new Promise<Response>((resolve) => {
    resolveOlder = resolve;
  });
  const item = (id: string) => ({
    id,
    rootId: "shared-videos",
    relativePath: `${id}.mkv`,
    mediaKind: "video",
    sizeBytes: 1024,
  });
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const path = String(input);
    if (path.endsWith("/items/Old")) return older;
    if (path.endsWith("/items/New")) return new Response(wireJson(item("New")));
    const payload = path.endsWith("/status")
      ? { mutationMode: "enabled", integrations: [] }
      : path.endsWith("/session")
        ? { username: "dsaw", groups: ["users"], canEdit: false }
        : path.endsWith("/roots")
          ? [
              {
                id: "shared-videos",
                label: "Videos",
                category: "videos",
                scope: "shared",
                available: true,
              },
            ]
          : path.includes("/items?")
            ? { items: [], nextCursor: null }
            : { available: false, progress: {} };
    return new Response(wireJson(payload));
  });
  vi.stubGlobal("fetch", fetchMock);
  const location = {
    search: "?view=library&root=shared-videos",
    pathname: "/",
  };
  vi.stubGlobal("window", {
    location,
    history: { pushState: vi.fn() },
    matchMedia: () => ({ matches: true }),
    requestAnimationFrame: (callback: () => void) => callback(),
    scrollTo: vi.fn(),
  });
  const { render, screen, userEvent } = await createDOM();
  await render(<Root initialView="library" initialRootId="shared-videos" />);
  const popstate = handlers.get("popstate");
  expect(popstate).toBeDefined();
  if (!popstate) return;
  location.search = "?view=library&root=shared-videos&item=Old";
  const navigatingOlder = popstate();
  // Attach a handler immediately; the finally block still awaits any failure.
  void navigatingOlder.catch(() => {});
  try {
    await vi.waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([input]) =>
          String(input).endsWith("/items/Old"),
        ),
      ).toBe(true),
    );
    location.search = "?view=library&root=shared-videos&item=New";
    await popstate();
    await userEvent(screen, "click");
    expect(
      fetchMock.mock.calls.some(([input]) =>
        String(input).endsWith("/items/New/metadata"),
      ),
    ).toBe(true);
    const countBeforeOlder = fetchMock.mock.calls.length;
    resolveOlder(new Response(wireJson(item("Old"))));
    await navigatingOlder;
    await userEvent(screen, "click");
    expect(
      fetchMock.mock.calls
        .slice(countBeforeOlder)
        .some(([input]) => String(input).endsWith("/items/Old/metadata")),
    ).toBe(false);
  } finally {
    resolveOlder(new Response(wireJson(item("Old"))));
    await navigatingOlder;
    await userEvent(screen, "click");
  }
});
