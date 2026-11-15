import { readFile, writeFile } from 'node:fs/promises';
import { dateParts } from './paths.js';
import type { ProbeResponse } from '../shared/types.js';

/**
 * Folder sidecars Media Manager reads to tell a YouTube channel folder and a
 * single video's folder apart from movies. The names and root elements are
 * Media Manager's (`src/metadata.rs`); Jellyfin ignores both files.
 */
export const CHANNEL_SIDECAR = 'channel.nfo';
export const VIDEO_SIDECAR = 'video.nfo';

/**
 * Folder artwork. Jellyfin and Media Manager both take `poster.jpg` as the
 * folder's own image: the channel avatar for a channel folder, the video
 * thumbnail for a chapter-split video's folder.
 */
export const FOLDER_POSTER = 'poster.jpg';

// NFO text is capped so an unusually long description cannot push the sidecar
// past Media Manager's safe-edit size limit.
const MAX_DESCRIPTION_CHARS = 20000;

const xmlText = (value: string): string =>
  value
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

const element = (name: string, value: string | undefined): string =>
  value && value.trim() ? `  <${name}>${xmlText(value.trim())}</${name}>\n` : '';

const description = (value: string | undefined): string | undefined =>
  value ? value.slice(0, MAX_DESCRIPTION_CHARS) : undefined;

const nfo = (root: string, body: string): string => `<?xml version="1.0" encoding="UTF-8"?>\n<${root}>\n${body}</${root}>\n`;

export const buildVideoNfo = (source: ProbeResponse, url: string): string => {
  const { year, date } = dateParts(source);
  return nfo(
    'youtubevideo',
    element('title', source.title) +
      element('year', year) +
      element('premiered', date && date.length === 10 ? date : undefined) +
      element('studio', source.channel || source.uploader) +
      element('plot', description(source.description)) +
      element('url', url) +
      (source.id ? `  <uniqueid type="youtube" default="true">${xmlText(source.id)}</uniqueid>\n` : ''),
  );
};

export type ChannelDetails = {
  name: string;
  id?: string;
  url?: string;
  description?: string;
};

export const buildChannelNfo = (channel: ChannelDetails): string =>
  nfo(
    'youtubechannel',
    element('title', channel.name) +
      element('plot', description(channel.description)) +
      element('url', channel.url) +
      (channel.id ? `  <uniqueid type="youtube" default="true">${xmlText(channel.id)}</uniqueid>\n` : ''),
  );

const CHANNEL_ID = /^UC[A-Za-z0-9_-]{22}$/;

/**
 * The canonical channel page for a probed channel ID. The URL is rebuilt from
 * a strictly shaped ID instead of taking any URL the extractor reported, so
 * the follow-up yt-dlp call can only ever reach a YouTube channel page.
 */
export const channelUrlFor = (channelId: string | undefined): string | undefined =>
  channelId && CHANNEL_ID.test(channelId) ? `https://www.youtube.com/channel/${channelId}` : undefined;

/** yt-dlp arguments that fetch only a channel's avatar and its description. */
export const channelArtworkArgs = (channelUrl: string, posterTemplate: string, infoTemplate: string): string[] => [
  '--no-config',
  '--no-warnings',
  '--flat-playlist',
  '--playlist-items',
  '0',
  '--skip-download',
  // A channel lists its banners and its avatar; yt-dlp ranks the uncropped
  // avatar first, so the "best" playlist thumbnail is the profile picture.
  '--write-thumbnail',
  '--convert-thumbnails',
  'jpg',
  '--write-info-json',
  '-o',
  `pl_thumbnail:${posterTemplate}`,
  '-o',
  `pl_infojson:${infoTemplate}`,
  channelUrl,
];

export const readChannelDescription = async (infoJsonPath: string): Promise<string | undefined> => {
  try {
    const info = JSON.parse(await readFile(infoJsonPath, 'utf8')) as { description?: unknown };
    return typeof info.description === 'string' ? info.description : undefined;
  } catch {
    return undefined;
  }
};

/** Write `contents` unless the file exists. Returns whether it was written. */
export const writeFileIfMissing = async (file: string, contents: string): Promise<boolean> => {
  try {
    await writeFile(file, contents, { flag: 'wx', mode: 0o664 });
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      return false;
    }
    throw error;
  }
};
