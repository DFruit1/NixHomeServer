/**
 * Responsive thumbnails. Image endpoints accept `?size=` (shortest side in
 * device pixels) and return a Lanczos-resized copy, so small tiles no longer
 * rely on the browser shrinking a full-size photo or cover several-fold,
 * which aliases into visible grain. The sizes match the server's fixed set.
 */
const THUMBNAIL_SIZES = [160, 320, 640] as const;

export const thumbnailSrc = (url: string) => `${url}?size=320`;

// Large tiles on high-density phones use the unresized image, which is at
// least Immich's 1440px preview for photos, or the original cover.
export const thumbnailSrcset = (url: string) =>
  [
    ...THUMBNAIL_SIZES.map((size) => `${url}?size=${size} ${size}w`),
    `${url} 1440w`,
  ].join(", ");

/**
 * `sizes` for a lazily loaded thumbnail. `auto` uses the rendered width where
 * supported; `fallback` is a CSS length (or media-condition list) otherwise.
 * Thumbnails fill their box with `object-fit: cover`, so the rendered width is
 * the box's long side, which is what the short side of the image must cover.
 */
export const thumbnailSizes = (fallback: string) => `auto, ${fallback}`;

/** Fallback `sizes` for a tile in an N-per-row collection layout. */
export const collectionTileSizes = (
  view: string,
  listPx: number,
  pane: { phone: string; desktop: string },
) => {
  const columns = Number(view.match(/^tiles-(\d)$/)?.[1] ?? 0);
  if (!columns) return thumbnailSizes(`${listPx}px`);
  return thumbnailSizes(
    `(max-width: 920px) calc(${pane.phone} / ${columns}), calc(${pane.desktop} / ${columns})`,
  );
};
