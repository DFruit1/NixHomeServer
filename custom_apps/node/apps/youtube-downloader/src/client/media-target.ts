import type { MediaType } from '../shared/types.js';

const AUDIO_EXTENSIONS = /\.(?:mp3|m4a|m4b|flac|opus|ogg|oga|aac|wav|wma|aiff?)$/i;
const VIDEO_EXTENSIONS = /\.(?:mp4|m4v|mkv|webm|mov|avi|3gp|ts)$/i;

/**
 * Pick the file the media app should open. Downloads can drop sidecar artwork
 * or metadata next to the media, so prefer the file extension that matches the
 * job kind and fall back to either media family.
 */
export const pickMediaFile = (
  files: string[],
  mediaType: MediaType,
): string | undefined => {
  const preferred = mediaType === 'video' ? VIDEO_EXTENSIONS : AUDIO_EXTENSIONS;
  return (
    files.find((file) => preferred.test(file)) ??
    files.find((file) => AUDIO_EXTENSIONS.test(file) || VIDEO_EXTENSIONS.test(file))
  );
};

/**
 * Build the `<folder>/<file>` path tail the media app matches against its
 * catalog `relativePath`. The folder is the leaf of the downloader's output
 * folder; the catalog stores the full path relative to its library root, so a
 * suffix match is enough to find the item.
 */
export const buildMediaTargetPath = (
  outputFolder: string | undefined,
  files: string[],
  mediaType: MediaType,
): string | undefined => {
  const folderName = outputFolder?.split(/[\\/]/).filter(Boolean).at(-1);
  const mediaFile = pickMediaFile(files, mediaType);
  return folderName && mediaFile ? `${folderName}/${mediaFile}` : undefined;
};
