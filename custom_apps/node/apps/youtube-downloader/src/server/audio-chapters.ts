import type { ChildProcess } from 'node:child_process';
import { cp, mkdir, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { runCommand } from './child.js';
import { sanitizeSegment } from './paths.js';
import type { AudioFormat, Chapter, ProbeResponse } from '../shared/types.js';

const MEDIA_EXTENSIONS = new Set([
  '.aac',
  '.avi',
  '.flac',
  '.m4a',
  '.m4v',
  '.mkv',
  '.mov',
  '.mp3',
  '.mp4',
  '.oga',
  '.ogg',
  '.opus',
  '.wav',
  '.webm',
]);
const THUMBNAIL_EXTENSIONS = new Set(['.jpg', '.jpeg']);

export const isMediaFile = (filePath: string): boolean => MEDIA_EXTENSIONS.has(path.extname(filePath).toLowerCase());

type ChildHooks = {
  isStopped: () => boolean;
  onSpawn: (child: ChildProcess) => void;
  onExit: (child: ChildProcess) => void;
};

type AudioChapterSpec = {
  chapter: Chapter;
  start: number;
  duration: number;
};

export const splitAudioChapters = async (
  tempDir: string,
  source: ProbeResponse,
  audioFormat: AudioFormat,
  embedCoverArt: boolean,
  childHooks?: ChildHooks,
): Promise<void> => {
  const input = await findDownloadedMedia(tempDir);
  const chapterDir = path.join(tempDir, 'chapters');
  await rm(chapterDir, { recursive: true, force: true });
  await mkdir(chapterDir, { recursive: true, mode: 0o750 });
  const coverPath = embedCoverArt ? await copyFirstThumbnail(tempDir, chapterDir) : undefined;

  const specs = audioChapterSpecs(source);
  for (const spec of specs) {
    if (childHooks?.isStopped()) {
      throw new Error('interrupted by service shutdown');
    }
    const title = sanitizeSegment(spec.chapter.title, 'Chapter');
    const output = path.join(chapterDir, `${String(spec.chapter.index).padStart(2, '0')} - ${title}.${audioFormat}`);
    const args = buildAudioChapterFfmpegArgs({
      input,
      output,
      chapter: spec.chapter,
      start: spec.start,
      duration: spec.duration,
      audioFormat,
      coverPath,
    });
    const timeoutMs = Math.max(120000, Math.ceil(spec.duration + 60) * 1000);
    let result = await runTrackedCommand('ffmpeg', args, timeoutMs, childHooks);
    if (result.code !== 0 && coverPath) {
      if (childHooks?.isStopped()) {
        throw new Error('interrupted by service shutdown');
      }
      result = await runTrackedCommand(
        'ffmpeg',
        buildAudioChapterFfmpegArgs({
          input,
          output,
          chapter: spec.chapter,
          start: spec.start,
          duration: spec.duration,
          audioFormat,
        }),
        timeoutMs,
        childHooks,
      );
    }
    if (result.code !== 0) {
      throw new Error(result.stderr.trim() || `ffmpeg exited with code ${result.code ?? 'unknown'} while splitting chapter ${spec.chapter.index}`);
    }
  }
};

const runTrackedCommand = async (
  command: string,
  args: string[],
  timeoutMs: number,
  childHooks?: Pick<ChildHooks, 'onSpawn' | 'onExit'>,
) => {
  let spawnedChild: ChildProcess | undefined;
  try {
    return await runCommand(command, args, {
      timeoutMs,
      onSpawn: (child) => {
        spawnedChild = child;
        childHooks?.onSpawn(child);
      },
    });
  } finally {
    if (spawnedChild) {
      childHooks?.onExit(spawnedChild);
    }
  }
};

type AudioChapterFfmpegArgs = {
  input: string;
  output: string;
  chapter: Chapter;
  start: number;
  duration: number;
  audioFormat: AudioFormat;
  coverPath?: string;
};

export const buildAudioChapterFfmpegArgs = ({
  input,
  output,
  chapter,
  start,
  duration,
  audioFormat,
  coverPath,
}: AudioChapterFfmpegArgs): string[] => {
  const embedCover = coverPath != null && audioFormatSupportsEmbeddedCover(audioFormat);
  return [
    '-hide_banner',
    '-nostdin',
    '-y',
    '-ss',
    formatSeconds(start),
    '-t',
    formatSeconds(duration),
    '-i',
    input,
    ...(embedCover ? ['-i', coverPath] : []),
    '-map',
    '0:a:0',
    ...(embedCover ? ['-map', '1:v:0'] : []),
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    ...audioEncoderArgs(audioFormat),
    ...(embedCover ? ['-c:v', 'mjpeg', '-disposition:v', 'attached_pic'] : ['-vn']),
    '-metadata',
    `title=${chapter.title}`,
    '-metadata',
    `track=${chapter.index}`,
    output,
  ];
};

const audioFormatSupportsEmbeddedCover = (audioFormat: AudioFormat): boolean => ['flac', 'm4a', 'mp3'].includes(audioFormat);

const audioEncoderArgs = (audioFormat: AudioFormat): string[] => {
  switch (audioFormat) {
    case 'flac':
      return ['-c:a', 'flac'];
    case 'wav':
      return ['-c:a', 'pcm_s16le'];
    case 'm4a':
      return ['-c:a', 'aac', '-b:a', '192k'];
    case 'mp3':
      return ['-c:a', 'libmp3lame', '-q:a', '2'];
    case 'opus':
      return ['-c:a', 'libopus', '-b:a', '128k'];
  }
};

const findDownloadedMedia = async (tempDir: string): Promise<string> => {
  const entries = await collectFiles(tempDir);
  const mediaFiles = entries.filter(isMediaFile);
  if (mediaFiles.length === 0) {
    throw new Error('yt-dlp did not produce a source media file for audio chapter splitting');
  }
  if (mediaFiles.length > 1) {
    throw new Error(`expected one source media file for audio chapter splitting, found ${mediaFiles.length}`);
  }
  return mediaFiles[0];
};

const copyFirstThumbnail = async (tempDir: string, chapterDir: string): Promise<string | undefined> => {
  const entries = await collectFiles(tempDir);
  const thumbnail = entries.find((entry) => THUMBNAIL_EXTENSIONS.has(path.extname(entry).toLowerCase()));
  if (!thumbnail) {
    return undefined;
  }
  const coverPath = path.join(chapterDir, 'cover.jpg');
  await cp(thumbnail, coverPath, {
    force: false,
    errorOnExist: true,
  });
  return coverPath;
};

export const audioChapterSpecs = (source: ProbeResponse): AudioChapterSpec[] =>
  source.chapters.map((chapter, index) => {
    const nextChapter = source.chapters[index + 1];
    const end = chapter.endTime ?? nextChapter?.startTime ?? source.durationSeconds;
    if (end == null) {
      throw new Error(`chapter ${chapter.index} is missing an end time and the source duration is unknown`);
    }
    const duration = end - chapter.startTime;
    if (!Number.isFinite(chapter.startTime) || !Number.isFinite(duration) || duration <= 0) {
      throw new Error(`chapter ${chapter.index} has an invalid start or end time`);
    }
    return {
      chapter,
      start: chapter.startTime,
      duration,
    };
  });

const formatSeconds = (seconds: number): string => seconds.toFixed(3);

export const collectFiles = async (directory: string): Promise<string[]> => {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await collectFiles(fullPath)));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
};
