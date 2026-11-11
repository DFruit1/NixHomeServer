// Work entirely in the browser, without sending covers to another service.
export async function coverColors(image: HTMLImageElement): Promise<string[]> {
  const { extractColorsFromImageBitmap } = await import("extract-colors");
  // The library uses input width/height as a crop. A bounded bitmap preserves
  // the complete intrinsic cover instead of sampling only a CSS thumbnail crop.
  const scale = Math.min(
    1,
    64 / Math.max(image.naturalWidth, image.naturalHeight),
  );
  const bitmap = await createImageBitmap(image, {
    resizeWidth: Math.max(1, Math.round(image.naturalWidth * scale)),
    resizeHeight: Math.max(1, Math.round(image.naturalHeight * scale)),
  });
  try {
    const colors = await extractColorsFromImageBitmap(bitmap, { pixels: 4096 });
    return colors
      .sort((a, b) => b.area - a.area)
      .slice(0, 3)
      .map((color) => color.hex);
  } finally {
    bitmap.close();
  }
}
