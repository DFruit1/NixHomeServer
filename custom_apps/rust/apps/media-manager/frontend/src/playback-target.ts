import type { CatalogItem } from "./root-types";

type TargetItem = Pick<CatalogItem, "id" | "relativePath">;

/**
 * A deep link from the YouTube Downloader carries either a durable item id or
 * the item's relative path (for example `_YouTube/<folder>/<file>`). The path
 * is matched by exact equality or by suffix, since the downloader only knows
 * the tail segment of the folder it wrote to.
 */
export function catalogItemMatchesTarget(
  item: TargetItem,
  itemId?: string,
  path?: string,
): boolean {
  if (itemId && item.id === itemId) {
    return true;
  }
  if (!path) {
    return false;
  }
  return item.relativePath === path || item.relativePath.endsWith(`/${path}`);
}

export function findTargetIndex(
  items: TargetItem[],
  itemId?: string,
  path?: string,
): number {
  if (!itemId && !path) {
    return -1;
  }
  return items.findIndex((item) =>
    catalogItemMatchesTarget(item, itemId, path),
  );
}

/** HEAD prepares the existing range-capable stream without holding a request
 * open for the encode. GET is used only once the cached MP4 is ready. */
export async function prepareBrowserPlayback(
  itemId: string,
  current: () => boolean,
): Promise<boolean> {
  let attempt = 0;
  while (current()) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000);
    let response: Response;
    try {
      response = await fetch(
        `/api/v1/items/${encodeURIComponent(itemId)}/stream?transcode=1`,
        {
          method: "HEAD",
          credentials: "same-origin",
          cache: "no-store",
          signal: controller.signal,
        },
      );
    } catch (error) {
      if (controller.signal.aborted)
        throw new Error(
          "Video preparation took too long to respond. Try again.",
        );
      throw error;
    } finally {
      clearTimeout(timer);
    }
    if (!current()) return false;
    if (response.status === 200) return true;
    if (response.status !== 202)
      throw new Error("The video could not be prepared for browser playback.");
    const delay = Math.min(1000 * 2 ** Math.min(attempt++, 3), 8000);
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  return false;
}
