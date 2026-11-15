import { cp, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { isMediaFile } from './audio-chapters.js';
import { allocateUniqueDestination, isInfoJsonSidecar, isSubtitleSidecar } from './output-move.js';
import { dateParts, sanitizeSegment } from './paths.js';
import { FOLDER_POSTER, VIDEO_SIDECAR } from './youtube-folders.js';
import type { AudioFormat, CreateJobRequest, Destination, ProbeResponse } from '../shared/types.js';

/**
 * Every download leaves a manifest in a hidden folder beside its files. The
 * manifest keeps what the download options would otherwise throw away — the
 * chapter list of an unsplit file, the thumbnail of an audio track whose cover
 * was not embedded, the names a different folder layout would use — so Media
 * Manager can later split or recombine chapters, re-embed or drop the cover,
 * and move the item between layouts and libraries without downloading again.
 *
 * The folder is dot-prefixed so Jellyfin and file browsers hide it, carries a
 * `.nomedia` so Android does not turn the thumbnails into a gallery album, and
 * Media Manager's scanner skips it by name (`ITEM_METADATA_FOLDER` in
 * `config.rs`). One folder serves every download filed in the same place, so
 * each manifest is named after its video ID.
 */
export const ITEM_METADATA_FOLDER = '.youtube-downloader';
export const ITEM_MANIFEST_SCHEMA = 'youtube-downloader.item';
export const ITEM_MANIFEST_VERSION = 1;

/** Which library the files were filed under. */
export type ManifestLibrary = 'music' | 'audiobooks' | 'videos';

/**
 * How the item's folder was chosen:
 * - `channel`: flat in the channel's folder beside its other downloads;
 * - `channel-video`: in its own folder inside the channel's folder (chapter splits);
 * - `title`: in its own folder named after the video, optionally under a year.
 */
export type ManifestLayout = 'channel' | 'channel-video' | 'title';

export type ManifestFileRole =
  | 'media'
  | 'chapter'
  | 'subtitle'
  | 'info-json'
  | 'thumbnail'
  | 'video-nfo'
  | 'video-poster'
  | 'other';

export type ManifestFile = {
  /** Relative to the item folder (the folder holding `ITEM_METADATA_FOLDER`), `/`-separated. */
  path: string;
  role: ManifestFileRole;
  /** The chapter a `chapter` file holds, matching `ManifestChapter.index`. */
  chapter?: number;
};

export type ManifestChapter = {
  index: number;
  title: string;
  startTime: number;
  /** Resolved from the next chapter or the duration when the source left it out. */
  endTime?: number;
};

export type ItemManifest = {
  schema: typeof ITEM_MANIFEST_SCHEMA;
  schemaVersion: typeof ITEM_MANIFEST_VERSION;
  /** What YouTube reported at download time. */
  source: {
    url: string;
    id?: string;
    title: string;
    channel?: string;
    channelId?: string;
    uploader?: string;
    releaseDate?: string;
    uploadDate?: string;
    durationSeconds?: number;
  };
  /** The download as it was requested. Media Manager never rewrites this. */
  download: {
    jobId: string;
    downloadedAt: string;
    downloadedBy: string;
    options: DownloadOptions;
  };
  /**
   * The sanitized names the downloader builds folders and files from, so any
   * other layout can be rebuilt exactly as a fresh download would name it.
   */
  naming: {
    title: string;
    channel: string;
    /** `YYYY-MM-DD`, or `YYYY` when YouTube only gave a year. */
    date?: string;
    year?: string;
  };
  /** Every chapter the source has, whether or not the files were split. */
  chapters: ManifestChapter[];
  /**
   * Where and how the item is filed now. Media Manager updates this block
   * (and `files`) whenever it splits, recombines, re-embeds or moves the item.
   */
  state: {
    destination: Destination;
    library: ManifestLibrary;
    /** The item folder relative to the library's YouTube root, `/`-separated. */
    folder: string;
    layout: ManifestLayout;
    split: boolean;
    /**
     * How the chapter files were cut: `stream-copy` (yt-dlp, video) keeps the
     * original encode, `re-encode` (ffmpeg, audio) encoded each chapter again
     * into `audioFormat`.
     */
    splitMethod?: 'stream-copy' | 're-encode';
    coverEmbedded: boolean;
  };
  files: ManifestFile[];
  /** The original YouTube thumbnail, relative to the item folder. */
  thumbnail?: string;
};

/** The request fields that shape the output; one-shot confirmations are dropped. */
export type DownloadOptions = Pick<
  CreateJobRequest,
  | 'destination'
  | 'mediaType'
  | 'audioFormat'
  | 'audioQuality'
  | 'videoContainer'
  | 'videoQuality'
  | 'splitChapters'
  | 'embedAudioCoverArt'
  | 'includeChannel'
  | 'includeDate'
  | 'saveAudioToAudiobooks'
  | 'downloadTranscript'
>;

export const downloadOptions = (request: CreateJobRequest): DownloadOptions => {
  const options: DownloadOptions = {
    destination: request.destination,
    mediaType: request.mediaType,
    splitChapters: request.splitChapters,
    includeChannel: request.includeChannel,
    includeDate: request.includeDate,
    downloadTranscript: request.downloadTranscript ?? false,
  };
  if (request.mediaType === 'audio') {
    options.audioFormat = request.audioFormat;
    options.audioQuality = request.audioQuality ?? 'best';
    options.embedAudioCoverArt = request.embedAudioCoverArt !== false;
    options.saveAudioToAudiobooks = request.saveAudioToAudiobooks ?? false;
  } else {
    options.videoContainer = request.videoContainer;
    options.videoQuality = request.videoQuality;
  }
  return options;
};

export const libraryFor = (request: CreateJobRequest): ManifestLibrary => {
  if (request.mediaType === 'video') {
    return 'videos';
  }
  return request.saveAudioToAudiobooks ? 'audiobooks' : 'music';
};

export const layoutFor = (request: CreateJobRequest): ManifestLayout => {
  if (!request.includeChannel) {
    return 'title';
  }
  return request.splitChapters ? 'channel-video' : 'channel';
};

/**
 * Chapters with every end time filled in, the way the audio splitter cuts
 * them. A chapter whose end cannot be resolved keeps only its start.
 */
export const manifestChapters = (source: ProbeResponse): ManifestChapter[] =>
  source.chapters.map((chapter, index) => {
    const end = chapter.endTime ?? source.chapters[index + 1]?.startTime ?? source.durationSeconds;
    const entry: ManifestChapter = { index: chapter.index, title: chapter.title, startTime: chapter.startTime };
    if (end != null && Number.isFinite(end) && end > chapter.startTime) {
      entry.endTime = end;
    }
    return entry;
  });

// Both splitters name chapter files `NN - <title>.<ext>` with a 1-based
// chapter number (yt-dlp's `section_number`, and our own ffmpeg splitter).
const CHAPTER_FILE = /^(\d{1,4}) - /;

export const classifyItemFile = (relativePath: string, split: boolean): ManifestFile => {
  const name = path.posix.basename(relativePath);
  if (isMediaFile(name)) {
    const chapter = split ? CHAPTER_FILE.exec(name)?.[1] : undefined;
    return chapter ? { path: relativePath, role: 'chapter', chapter: Number.parseInt(chapter, 10) } : { path: relativePath, role: 'media' };
  }
  if (isSubtitleSidecar(name)) {
    return { path: relativePath, role: 'subtitle' };
  }
  if (isInfoJsonSidecar(name)) {
    return { path: relativePath, role: 'info-json' };
  }
  if (name === VIDEO_SIDECAR) {
    return { path: relativePath, role: 'video-nfo' };
  }
  if (name === FOLDER_POSTER) {
    return { path: relativePath, role: 'video-poster' };
  }
  if (/\.jpe?g$/i.test(name)) {
    return { path: relativePath, role: 'thumbnail' };
  }
  return { path: relativePath, role: 'other' };
};

const COVER_EMBEDDABLE_WHEN_SPLIT: AudioFormat[] = ['flac', 'm4a', 'mp3'];

/** Whether the files carry the thumbnail as embedded cover art. */
export const coverEmbeddedFor = (request: CreateJobRequest): boolean => {
  if (request.mediaType === 'video') {
    return true;
  }
  if (request.embedAudioCoverArt === false) {
    return false;
  }
  const format = request.audioFormat ?? 'flac';
  // The chapter splitter only attaches covers to formats with a picture
  // stream; yt-dlp embeds into everything it was asked to produce but WAV.
  return request.splitChapters ? COVER_EMBEDDABLE_WHEN_SPLIT.includes(format) : format !== 'wav';
};

const toPosix = (value: string): string => value.split(path.sep).join('/');

export type BuildItemManifestInput = {
  jobId: string;
  downloadedBy: string;
  downloadedAt: string;
  request: CreateJobRequest;
  source: ProbeResponse;
  /** The library's YouTube root the item was filed under. */
  libraryRoot: string;
  /** The folder holding the item's files (and the metadata folder). */
  itemFolder: string;
  /** Absolute paths of the files this download wrote into `itemFolder`. */
  files: string[];
  /** The archived thumbnail's absolute path, if one was kept. */
  thumbnail?: string;
};

export const buildItemManifest = (input: BuildItemManifestInput): ItemManifest => {
  const { request, source } = input;
  const split = request.splitChapters;
  const { year, date } = dateParts(source);
  const files = input.files
    .map((file) => classifyItemFile(toPosix(path.relative(input.itemFolder, file)), split))
    .sort((a, b) => (a.chapter ?? 0) - (b.chapter ?? 0) || a.path.localeCompare(b.path));
  return {
    schema: ITEM_MANIFEST_SCHEMA,
    schemaVersion: ITEM_MANIFEST_VERSION,
    source: {
      url: request.url,
      id: source.id,
      title: source.title,
      channel: source.channel,
      channelId: source.channelId,
      uploader: source.uploader,
      releaseDate: source.releaseDate,
      uploadDate: source.uploadDate,
      durationSeconds: source.durationSeconds,
    },
    download: {
      jobId: input.jobId,
      downloadedAt: input.downloadedAt,
      downloadedBy: input.downloadedBy,
      options: downloadOptions(request),
    },
    naming: {
      title: sanitizeSegment(source.title, 'Unknown Title'),
      channel: sanitizeSegment(source.channel || source.uploader, 'Unknown Channel'),
      date,
      year,
    },
    chapters: manifestChapters(source),
    state: {
      destination: request.destination,
      library: libraryFor(request),
      folder: toPosix(path.relative(input.libraryRoot, input.itemFolder)),
      layout: layoutFor(request),
      split,
      splitMethod: split ? (request.mediaType === 'video' ? 'stream-copy' : 're-encode') : undefined,
      coverEmbedded: coverEmbeddedFor(request),
    },
    files,
    thumbnail: input.thumbnail ? toPosix(path.relative(input.itemFolder, input.thumbnail)) : undefined,
  };
};

/** The manifest file's stem: the video ID, or the sanitized title without one. */
export const manifestStem = (source: ProbeResponse): string =>
  source.id && /^[A-Za-z0-9_-]{1,64}$/.test(source.id) ? source.id : sanitizeSegment(source.title, 'item');

/**
 * Create the item folder's metadata folder (with its `.nomedia` marker) and
 * reserve a manifest name no other download into the same folder holds, by
 * creating it empty. `writeItemManifest` later replaces the placeholder.
 * Returns the folder and the reserved stem.
 */
export const prepareItemMetadataFolder = async (
  itemFolder: string,
  stem: string,
): Promise<{ folder: string; stem: string }> => {
  const folder = path.join(itemFolder, ITEM_METADATA_FOLDER);
  await mkdir(folder, { recursive: true, mode: 0o775 });
  await writeFile(path.join(folder, '.nomedia'), '', { flag: 'a', mode: 0o664 });
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const candidate = path.basename(await allocateUniqueDestination(folder, `${stem}.json`), '.json');
    try {
      await writeFile(path.join(folder, `${candidate}.json`), '', { flag: 'wx', mode: 0o664 });
      return { folder, stem: candidate };
    } catch (error) {
      // Another job filing into the same folder took the name in between.
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') {
        throw error;
      }
    }
  }
  throw new Error(`could not reserve a manifest name for ${stem} under ${folder}`);
};

/** Keep a copy of the original thumbnail as `<stem>.jpg` in the metadata folder. */
export const archiveThumbnail = async (thumbnail: string, metadataFolder: string, stem: string): Promise<string> => {
  const destination = path.join(metadataFolder, `${stem}.jpg`);
  // The stem is reserved, so a file already here is a leftover of an earlier
  // failed write under the same name and is safe to replace.
  await cp(thumbnail, destination, { force: true });
  return destination;
};

/**
 * Write the manifest through a temporary file and a rename so a reader (or a
 * later rewrite by Media Manager) never sees half a document.
 */
export const writeItemManifest = async (metadataFolder: string, stem: string, manifest: ItemManifest): Promise<string> => {
  const destination = path.join(metadataFolder, `${stem}.json`);
  const partial = path.join(metadataFolder, `.${stem}.${randomUUID()}.tmp`);
  try {
    await writeFile(partial, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx', mode: 0o664 });
    await rename(partial, destination);
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  }
  return destination;
};
