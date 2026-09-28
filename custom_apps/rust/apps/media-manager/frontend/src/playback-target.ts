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
