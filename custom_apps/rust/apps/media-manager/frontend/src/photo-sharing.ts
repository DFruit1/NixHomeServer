import type { ImmichImage } from "./api-contract.generated";
import { readableError, type ServerError } from "./api";

// Keep a large selection from exhausting a phone's memory. ZIP downloads stream
// through the browser and do not have this in-memory sharing limit.
const MAX_SHARE_BYTES = 100 * 1024 * 1024;
export async function preparePhotoFiles(
  photos: Pick<ImmichImage, "id" | "filename">[],
  signal: AbortSignal,
): Promise<File[]> {
  const files: File[] = [];
  let size = 0;
  for (const photo of photos) {
    const response = await fetch(
      `/api/v1/provider-lookups/immich/images/${encodeURIComponent(photo.id)}/original`,
      { credentials: "same-origin", signal },
    );
    if (!response.ok) {
      const payload = (await response.json().catch(() => ({}))) as ServerError;
      throw new Error(
        payload.error?.message ?? "The photo could not be downloaded.",
      );
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("The photo could not be downloaded.");
    const chunks: Uint8Array<ArrayBuffer>[] = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > MAX_SHARE_BYTES)
          throw new Error(
            "Select fewer photos to share (up to 100 MB), or download them instead.",
          );
        chunks.push(value);
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw new Error(readableError(error));
    } finally {
      reader.releaseLock();
    }
    files.push(
      new File(chunks, photo.filename.split(/[/\\]/).pop() || "photo", {
        type:
          response.headers.get("content-type")?.split(";")[0] ||
          "application/octet-stream",
      }),
    );
  }
  return files;
}
