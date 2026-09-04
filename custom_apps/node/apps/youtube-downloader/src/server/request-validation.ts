import { isIP } from 'node:net';
import type { AppConfig } from './config.js';
import type { CreateJobRequest, ProbeResponse } from '../shared/types.js';

const ALLOWED_DOWNLOAD_HOSTS = ['youtube.com', 'youtu.be', 'youtube-nocookie.com'];
const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const YOUTUBE_PLAYLIST_ID = /^[A-Za-z0-9_-]{2,128}$/;
const YOUTUBE_CHANNEL_SEGMENT = /^[A-Za-z0-9_.@-]{1,128}$/;
const YOUTUBE_CHANNEL_TABS = new Set(['featured', 'playlists', 'shorts', 'streams', 'videos']);

export const validateRequest = (request: CreateJobRequest): void => {
  validateDownloadUrl(request.url);
  if (request.destination !== 'personal' && request.destination !== 'shared') {
    throw new Error('destination must be personal or shared');
  }
  if (typeof request.splitChapters !== 'boolean') {
    throw new Error('split chapters flag must be a boolean');
  }
  if (request.ytDlpVersion !== 'packaged') {
    throw new Error('yt-dlp version must be the reproducible packaged build');
  }
  if (request.mediaType === 'audio') {
    if (!request.audioFormat || !['flac', 'm4a', 'mp3', 'opus', 'wav'].includes(request.audioFormat)) {
      throw new Error('unsupported audio format');
    }
    if (request.audioQuality && !['best', 'high', 'medium', 'low'].includes(request.audioQuality)) {
      throw new Error('unsupported audio quality');
    }
    if (request.saveAudioToAudiobooks != null && typeof request.saveAudioToAudiobooks !== 'boolean') {
      throw new Error('audiobook destination flag must be a boolean');
    }
    if (request.embedAudioCoverArt != null && typeof request.embedAudioCoverArt !== 'boolean') {
      throw new Error('audio cover art flag must be a boolean');
    }
  } else if (request.mediaType === 'video') {
    if (!request.videoContainer || !['mkv', 'mp4', 'webm'].includes(request.videoContainer)) {
      throw new Error('unsupported video container');
    }
    if (!request.videoQuality || !['best', '2160p', '1440p', '1080p', '720p', '480p'].includes(request.videoQuality)) {
      throw new Error('unsupported video quality');
    }
  } else {
    throw new Error('media type must be audio or video');
  }
};

export const validateDownloadUrl = (rawUrl: string): void => {
  if (typeof rawUrl !== 'string' || rawUrl.length > 2048) {
    throw new Error('download URL must be at most 2048 characters');
  }
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error('download URL is invalid');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('download URL must use http or https');
  }
  if (parsed.username || parsed.password) {
    throw new Error('download URL must not contain credentials');
  }
  const hostname = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (hostname === 'localhost' || hostname.endsWith('.localhost') || isPrivateAddress(hostname)) {
    throw new Error('download URL must not target a local or private address');
  }
  if (!ALLOWED_DOWNLOAD_HOSTS.some((allowed) => hostname === allowed || hostname.endsWith(`.${allowed}`))) {
    throw new Error('download URL host is not supported; only YouTube URLs are allowed');
  }
  if (parsed.protocol !== 'https:' || parsed.port) {
    throw new Error('YouTube download URLs must use HTTPS on the default port');
  }
  if (!isSupportedYouTubePath(parsed, hostname)) {
    throw new Error('download URL must identify a supported YouTube video, playlist, or channel');
  }
};

const isSupportedYouTubePath = (url: URL, hostname: string): boolean => {
  const segments = url.pathname.split('/').filter(Boolean);
  if (hostname === 'youtu.be' || hostname.endsWith('.youtu.be')) {
    return segments.length === 1 && YOUTUBE_VIDEO_ID.test(segments[0]);
  }
  if (hostname === 'youtube-nocookie.com' || hostname.endsWith('.youtube-nocookie.com')) {
    return segments.length === 2 && segments[0] === 'embed' && YOUTUBE_VIDEO_ID.test(segments[1]);
  }
  if (url.pathname === '/watch') {
    const videoId = url.searchParams.get('v');
    const playlistId = url.searchParams.get('list');
    return (videoId != null && YOUTUBE_VIDEO_ID.test(videoId))
      || (videoId == null && playlistId != null && YOUTUBE_PLAYLIST_ID.test(playlistId));
  }
  if (url.pathname === '/playlist') {
    const playlistId = url.searchParams.get('list');
    return playlistId != null && YOUTUBE_PLAYLIST_ID.test(playlistId);
  }
  if (segments[0]?.startsWith('@')) {
    return YOUTUBE_CHANNEL_SEGMENT.test(segments[0])
      && (segments.length === 1 || (segments.length === 2 && YOUTUBE_CHANNEL_TABS.has(segments[1])));
  }
  if (['c', 'channel', 'user'].includes(segments[0])) {
    return segments.length >= 2
      && segments.length <= 3
      && YOUTUBE_CHANNEL_SEGMENT.test(segments[1])
      && (segments.length === 2 || YOUTUBE_CHANNEL_TABS.has(segments[2]));
  }
  return segments.length === 2
    && ['embed', 'live', 'shorts', 'v'].includes(segments[0])
    && YOUTUBE_VIDEO_ID.test(segments[1]);
};

export const normalizeCreateJobRequest = (request: CreateJobRequest): CreateJobRequest => ({
  ...request,
  ytDlpVersion: 'packaged',
  splitChapters: request.splitChapters ?? true,
  embedAudioCoverArt: request.mediaType === 'audio' ? (request.embedAudioCoverArt ?? true) : undefined,
});

export const ytDlpPathFor = (config: AppConfig, _request: CreateJobRequest): string => config.ytDlpPath;

const isPrivateAddress = (hostname: string): boolean => {
  const mappedAddress = ipv4FromMappedIpv6(hostname);
  if (mappedAddress) {
    return isPrivateAddress(mappedAddress);
  }
  const family = isIP(hostname);
  if (family === 4) {
    const [a, b] = hostname.split('.').map(Number);
    return a === 0
      || a === 10
      || a === 127
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127)
      || a >= 224;
  }
  if (family === 6) {
    return hostname === '::1'
      || hostname === '::'
      || hostname.startsWith('fc')
      || hostname.startsWith('fd')
      || /^fe[89ab]/.test(hostname)
      || hostname.startsWith('ff');
  }
  return false;
};

const ipv4FromMappedIpv6 = (hostname: string): string | undefined => {
  const match = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i.exec(hostname);
  if (!match) {
    return undefined;
  }
  const high = Number.parseInt(match[1], 16);
  const low = Number.parseInt(match[2], 16);
  return `${high >>> 8}.${high & 0xff}.${low >>> 8}.${low & 0xff}`;
};

export const chapterGateFor = (request: CreateJobRequest, source: ProbeResponse): 'download' | 'single-file' | 'alert' => {
  if (request.splitChapters && source.chapters.length === 0) {
    return 'single-file';
  }
  if (!request.splitChapters && source.chapters.length > 0 && !request.chaptersConfirmed) {
    return 'alert';
  }
  return 'download';
};
