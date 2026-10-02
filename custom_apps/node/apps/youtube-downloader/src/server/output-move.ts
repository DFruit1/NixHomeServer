import { access, cp, readdir } from 'node:fs/promises';
import path from 'node:path';

// yt-dlp writes loose thumbnail images next to the media when --write-thumbnail
// is set. Those sidecars are useful in the job temp directory (chapter splitting
// embeds them) but must never reach the shared media library: Android's media
// scanner turns every image into a gallery album, and music apps can apply one
// folder image to every track in a shared folder, overriding per-track
// embedded artwork.
const ARTWORK_SIDECAR_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.webp']);

export const isArtworkSidecar = (name: string): boolean =>
  ARTWORK_SIDECAR_EXTENSIONS.has(path.extname(name).toLowerCase());

// Subtitle sidecars sit next to the media file too, but chapter splitting only
// ever relocates the media itself — yt-dlp's own splitter for video, ours for
// audio — which leaves the transcripts behind in the temp root. They are
// copied across separately so a chaptered download keeps its transcript.
// `.srt` is what the transcript option produces; the rest guard against a
// future extractor dropping the conversion.
const SUBTITLE_SIDECAR_EXTENSIONS = new Set(['.srt', '.vtt', '.ass', '.ssa', '.lrc']);

export const isSubtitleSidecar = (name: string): boolean =>
  SUBTITLE_SIDECAR_EXTENSIONS.has(path.extname(name).toLowerCase());

/** Copy only subtitle sidecars, leaving every other temp-directory file behind. */
export const copySubtitleSidecars = async (sourceDir: string, destinationDir: string): Promise<void> => {
  const entries = await readdir(sourceDir, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isFile() || !isSubtitleSidecar(entry.name)) {
      continue;
    }
    const destination = await allocateUniqueDestination(destinationDir, entry.name);
    await cp(path.join(sourceDir, entry.name), destination, {
      force: false,
      errorOnExist: true,
    });
  }
};

export type CopyDirectoryOptions = {
  /** Skip loose image files so only media and metadata reach the destination. */
  skipArtworkSidecars?: boolean;
};

export const copyDirectoryContents = async (
  sourceDir: string,
  destinationDir: string,
  options: CopyDirectoryOptions = {},
): Promise<void> => {
  const entries = await readdir(sourceDir, { withFileTypes: true });
  for (const entry of entries) {
    if (options.skipArtworkSidecars && entry.isFile() && isArtworkSidecar(entry.name)) {
      continue;
    }
    const destination = await allocateUniqueDestination(destinationDir, entry.name);
    await cp(path.join(sourceDir, entry.name), destination, {
      recursive: true,
      force: false,
      errorOnExist: true,
    });
  }
};

export const allocateUniqueDestination = async (directory: string, name: string): Promise<string> => {
  const extension = path.extname(name);
  const base = extension ? name.slice(0, -extension.length) : name;
  for (let index = 0; index < 1000; index += 1) {
    const candidate = index === 0 ? name : `${base} (${index})${extension}`;
    try {
      await access(path.join(directory, candidate));
    } catch {
      return path.join(directory, candidate);
    }
  }
  throw new Error(`could not allocate a unique output name for ${name} under ${directory}`);
};
