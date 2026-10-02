import type { AppConfig } from './config.js';
import type { ChildProcess } from 'node:child_process';
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
  subtitles?: Record<string, unknown>;
  entries?: unknown[];
  _type?: string;
};

const VIDEO_FORMAT_SORT = '+vcodec:avc,+acodec:m4a,res,fps,br';

// --convert-subs runs through ffmpeg, which cannot demux YouTube's json3 or
// srv1/2/3 formats. The extractor offers WebVTT for every caption track, and
// the vtt -> srt conversion preserves cue text, timings and unicode, so vtt is
// requested first and only falls back if a future extractor drops it.
const TRANSCRIPT_SUB_FORMAT = 'vtt/best';

// yt-dlp matches --sub-langs entries as regular expressions against the track
// tags the extractor produced, so a tag has to be restricted to characters that
// cannot change the meaning of the surrounding expression.
const SUBTITLE_TAG = /^[A-Za-z0-9-]{1,64}$/;

// A request is one YouTube video's worth of manual subtitles in practice; the
// cap only exists so a surprising track list cannot balloon the download.
const MAX_MANUAL_SUBTITLE_LANGUAGES = 12;

/**
 * Build the `--sub-langs` value for the transcript option.
 *
 * `.*-orig` matches the track the video was actually made in — the only tag
 * the extractor invents that means "original", and the one that covers the
 * automatic transcript without the server having to know the language.
 * `en` then adds the English track, whether uploaded or auto-translated.
 *
 * Everything else on YouTube is a machine translation of a caption into roughly
 * a hundred languages; `all`, or a loose `en.*`, sweeps those in and turns a
 * two-file transcript into a dozen near-duplicates. What is left to add is the
 * human-authored tracks the probe reported, so a video with uploaded subtitles
 * but no speech recognition still gets them. Playlist and channel jobs are
 * probed flat and carry no per-video subtitle information, so they fall back to
 * the transcript and English alone.
 */
export const transcriptSubLangs = (source: ProbeResponse): string => {
  const langs = ['.*-orig', 'en'];
  for (const lang of source.subtitleLanguages ?? []) {
    if (langs.length >= MAX_MANUAL_SUBTITLE_LANGUAGES) {
      break;
    }
    if (SUBTITLE_TAG.test(lang) && !langs.includes(lang)) {
      langs.push(lang);
    }
  }
  return langs.join(',');
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

export const probeUrl = async (
  config: AppConfig,
  url: string,
  onSpawn?: (child: ChildProcess) => void,
  ytDlpPath = config.ytDlpPath,
): Promise<ProbeResponse> => {
  const result = await runCommand(ytDlpPath, ['--no-config', '--dump-single-json', '--flat-playlist', '--no-warnings', url], {
    timeoutMs: 120000,
    onSpawn,
  });
  if (result.signal === 'SIGTERM' || result.signal === 'SIGKILL') {
    throw new Error('cancelled by user');
  }
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
    // Playlist and channel entries are probed flat, so only single videos
    // report their human-authored subtitle tracks here.
    subtitleLanguages: isPlaylist ? undefined : Object.keys(raw.subtitles ?? {}),
  };
};

export const buildDownloadArgs = (
  request: CreateJobRequest,
  outputTemplate: string,
  chapterTemplate: string,
  subLangs: string = '.*-orig,en',
): string[] => {
  const args = [
    '--no-config',
    '--newline',
    '--no-simulate',
    '--no-overwrites',
    '--windows-filenames',
    '--write-info-json',
    '--write-thumbnail',
    '--convert-thumbnails',
    'jpg',
    '--embed-metadata',
    '-o',
    outputTemplate,
  ];

  if (request.mediaType !== 'audio' || request.embedAudioCoverArt !== false) {
    args.push('--embed-thumbnail');
  }

  if (request.downloadTranscript) {
    args.push(
      '--write-subs',
      '--write-auto-subs',
      '--sub-langs',
      subLangs,
      '--sub-format',
      TRANSCRIPT_SUB_FORMAT,
      '--convert-subs',
      'srt',
    );
  }

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
      '--format-sort',
      VIDEO_FORMAT_SORT,
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
