import type { AppConfig } from './config.js';
import { runCommand } from './child.js';
import type { AudioFormat, AudioQuality, CreateJobRequest, ProbeResponse, VideoQuality } from '../shared/types.js';

type RawChapter = {
  title?: string;
  start_time?: number;
  end_time?: number;
};

type RawProbe = {
  id?: string;
  title?: string;
  channel?: string;
  uploader?: string;
  duration?: number;
  release_date?: string;
  upload_date?: string;
  chapters?: RawChapter[];
  entries?: unknown[];
  _type?: string;
};

const videoSelector = (quality: VideoQuality): string => {
  if (quality === 'best') {
    return 'bestvideo+bestaudio/best';
  }
  const height = quality.replace('p', '');
  return `bestvideo[height<=${height}]+bestaudio/best[height<=${height}]/best`;
};

const audioQualityValue = (quality: AudioQuality): string => {
  switch (quality) {
    case 'best':
      return '0';
    case 'high':
      return '2';
    case 'medium':
      return '5';
    case 'low':
      return '7';
  }
};

export const probeUrl = async (config: AppConfig, url: string): Promise<ProbeResponse> => {
  const result = await runCommand(config.ytDlpPath, ['--dump-single-json', '--flat-playlist', '--no-warnings', url], {
    timeoutMs: 120000,
  });
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() || `yt-dlp probe exited with code ${result.code ?? 'unknown'}`);
  }
  const raw = JSON.parse(result.stdout) as RawProbe;
  const chapters = (raw.chapters ?? []).map((chapter, index) => ({
    index: index + 1,
    title: chapter.title || `Chapter ${index + 1}`,
    startTime: chapter.start_time ?? 0,
    endTime: chapter.end_time,
  }));
  const isPlaylist = raw._type === 'playlist' || Array.isArray(raw.entries);
  return {
    title: raw.title || 'Unknown Title',
    id: raw.id,
    channel: raw.channel,
    uploader: raw.uploader,
    durationSeconds: raw.duration,
    releaseDate: raw.release_date,
    uploadDate: raw.upload_date,
    effectiveDate: raw.release_date || raw.upload_date,
    chapters,
    isPlaylist,
    entries: Array.isArray(raw.entries) ? raw.entries.length : undefined,
  };
};

export const buildDownloadArgs = (request: CreateJobRequest, outputTemplate: string, chapterTemplate: string): string[] => {
  const args = [
    '--newline',
    '--no-simulate',
    '--no-overwrites',
    '--write-info-json',
    '--write-thumbnail',
    '--convert-thumbnails',
    'jpg',
    '--embed-metadata',
    '--embed-thumbnail',
    '-o',
    outputTemplate,
  ];

  if (request.splitChapters && request.mediaType === 'video') {
    args.push('--split-chapters', '-o', `chapter:${chapterTemplate}`);
  } else {
    args.push('--embed-chapters');
  }

  if (request.mediaType === 'audio') {
    const audioFormat: AudioFormat = request.audioFormat ?? 'flac';
    args.push('-x', '--audio-format', audioFormat, '--audio-quality', audioQualityValue(request.audioQuality ?? 'best'), '-f', 'bestaudio/best');
  } else {
    args.push(
      '-f',
      videoSelector(request.videoQuality ?? 'best'),
      '--merge-output-format',
      request.videoContainer ?? 'mkv',
    );
  }

  args.push(request.url);
  return args;
};

export const parseProgress = (line: string): { percent?: number; speed?: string; eta?: string } | undefined => {
  const percent = /\[download]\s+([0-9.]+)%/.exec(line)?.[1];
  if (!percent) {
    return undefined;
  }
  return {
    percent: Number.parseFloat(percent),
    speed: /\sat\s+([^\s]+)/.exec(line)?.[1],
    eta: /\sETA\s+([^\s]+)/.exec(line)?.[1],
  };
};
