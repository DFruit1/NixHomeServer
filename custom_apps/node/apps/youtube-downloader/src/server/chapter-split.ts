import type { ChildProcess } from 'node:child_process';
import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { runCommand, type SpawnResult } from './child.js';
import { sanitizeSegment } from './paths.js';
import type { Chapter } from '../shared/types.js';

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

export const isMediaFile = (filePath: string): boolean => MEDIA_EXTENSIONS.has(path.extname(filePath).toLowerCase());

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

/** The one media file yt-dlp left in `directory`. */
export const findDownloadedMedia = async (directory: string): Promise<string> => {
  const entries = await readdir(directory, { withFileTypes: true });
  const media = entries.filter((entry) => entry.isFile() && isMediaFile(entry.name)).map((entry) => path.join(directory, entry.name));
  if (media.length !== 1) {
    throw new Error(`expected one downloaded media file to split, found ${media.length}`);
  }
  return media[0];
};

/*
 * Lossless chapter splitting.
 *
 * Nothing is re-encoded. ffmpeg's segment muxer copies the coded packets of
 * the source into one file per chapter, so every packet lands in exactly one
 * chapter file and concatenating the chapter files gives back the source's
 * packets bit for bit. Each split is checked for exactly that before it is
 * used: the per-stream packet hash of the source must equal the hash of the
 * chapter files read back to back.
 *
 * Packets cannot be cut in half, so a chapter boundary moves to the nearest
 * packet at or after the chapter's start: within a few milliseconds for audio,
 * and to the next keyframe (usually under a few seconds) for video. The cut
 * points actually used are recorded per chapter file.
 *
 * Containers that trim an encoder delay (AAC in MP4/M4A) lose that trim on
 * the first chapter, which then starts with ~21 ms of decoder warm-up. The
 * source's earliest timestamp per stream is recorded so a recombination can
 * restore the trim and decode to exactly the source's samples and frames.
 */

/** One coded stream of the source, as needed to recombine and verify it. */
export type SplitStream = {
  type: 'video' | 'audio';
  codec: string;
  /** Rational time base of `startPts`, e.g. `1/48000`. */
  timeBase: string;
  /** The stream's earliest presentation timestamp in the source. */
  startPts: number;
  /** MD5 over every packet of the stream, from ffmpeg's `streamhash` muxer. */
  packetMd5: string;
};

export type SplitPart = {
  chapter: Chapter;
  file: string;
  /** Where the chapter file actually starts and ends in the source, in seconds. */
  start: number;
  end: number;
};

export type LosslessSplit = {
  extension: string;
  streams: SplitStream[];
  parts: SplitPart[];
};

type ChildHooks = {
  isStopped: () => boolean;
  onSpawn: (child: ChildProcess) => void;
  onExit: (child: ChildProcess) => void;
};

export type SplitOptions = {
  input: string;
  chapters: Chapter[];
  /** Receives the finished chapter files. */
  outputDir: string;
  /** Private scratch space, removed afterwards. */
  workDir: string;
  /** Embedded as cover art when the container supports it. */
  coverPath?: string;
  /** Total source length in seconds, used only to size command timeouts. */
  durationSeconds?: number;
  childHooks?: ChildHooks;
};

/** Audio containers that take a cover picture as an attached-picture stream. */
const COVER_EXTENSIONS = new Set(['.flac', '.m4a', '.mp3']);

// The coded streams that make up the programme: video that is not an attached
// cover picture, and every audio track. Covers and other attachments are
// container decoration and are re-added per chapter.
const PROGRAMME_STREAMS = ['-map', '0:V?', '-map', '0:a'];

export const chapterFileName = (chapter: Chapter, total: number, extension: string): string => {
  const width = Math.max(2, String(total).length);
  return `${String(chapter.index).padStart(width, '0')} - ${sanitizeSegment(chapter.title, 'Chapter')}${extension}`;
};

/** `-segment_times` for the chapters after the first, or an error when they do not ascend. */
export const segmentTimes = (chapters: Chapter[]): string => {
  if (chapters.length < 2) {
    throw new Error('a split needs at least two chapters');
  }
  let previous = 0;
  const times = chapters.slice(1).map((chapter) => {
    if (!Number.isFinite(chapter.startTime) || chapter.startTime <= previous) {
      throw new Error(`chapter ${chapter.index} does not start after the chapter before it`);
    }
    previous = chapter.startTime;
    return chapter.startTime.toFixed(6);
  });
  return times.join(',');
};

export const buildSegmentArgs = (input: string, chapters: Chapter[], listFile: string, pattern: string): string[] => [
  '-nostdin',
  '-hide_banner',
  '-v',
  'error',
  '-y',
  '-i',
  input,
  ...PROGRAMME_STREAMS,
  '-c',
  'copy',
  '-f',
  'segment',
  '-segment_times',
  segmentTimes(chapters),
  '-reset_timestamps',
  '1',
  '-segment_list',
  listFile,
  '-segment_list_type',
  'csv',
  pattern,
];

export const buildChapterFinishArgs = (
  part: string,
  output: string,
  chapter: Chapter,
  total: number,
  coverPath: string | undefined,
): string[] => {
  const cover = coverPath != null && COVER_EXTENSIONS.has(path.extname(output).toLowerCase());
  return [
    '-nostdin',
    '-hide_banner',
    '-v',
    'error',
    '-y',
    '-i',
    part,
    ...(cover ? ['-i', coverPath] : []),
    '-map',
    '0',
    ...(cover ? ['-map', '1:v:0'] : []),
    '-c',
    'copy',
    // The picture is the only video stream an audio chapter has.
    ...(cover ? ['-c:v', 'mjpeg', '-disposition:v:0', 'attached_pic'] : []),
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    '-metadata',
    `title=${chapter.title}`,
    '-metadata',
    `track=${chapter.index}/${total}`,
    output,
  ];
};

/**
 * Per-stream packet hashes of `inputArgs`: of its programme streams, or of
 * its first `streamCount` streams. Joined chapter files are hashed by
 * position because the concat reader drops the attached-picture flag that
 * otherwise tells a cover apart from video; the finished chapters keep the
 * programme streams first and any cover after them.
 */
export const buildStreamHashArgs = (inputArgs: string[], streamCount?: number): string[] => [
  '-nostdin',
  '-hide_banner',
  '-v',
  'error',
  ...inputArgs,
  ...(streamCount == null ? PROGRAMME_STREAMS : Array.from({ length: streamCount }, (_, index) => ['-map', `0:${index}`]).flat()),
  '-c',
  'copy',
  '-f',
  'streamhash',
  '-hash',
  'md5',
  '-',
];

/** Lines of `streamhash` output (`0,a,MD5=…`) in stream order. */
export const parseStreamHashes = (output: string): string[] =>
  output
    .split(/\r?\n/)
    .map((line) => /^\d+,[a-z],MD5=([0-9a-f]{32})$/.exec(line.trim())?.[1])
    .filter((hash): hash is string => hash != null);

/** `filename,start,end` rows of the segment muxer's CSV list. */
export const parseSegmentList = (csv: string): { name: string; start: number; end: number }[] =>
  csv
    .split(/\r?\n/)
    .filter((line) => line.trim())
    .map((line) => {
      // The name is the only field that could contain a comma.
      const match = /^(.*),([^,]+),([^,]+)$/.exec(line);
      if (!match) {
        throw new Error(`unreadable segment list line: ${line}`);
      }
      return { name: match[1].replace(/^"|"$/g, ''), start: Number.parseFloat(match[2]), end: Number.parseFloat(match[3]) };
    });

/** A line of an ffmpeg concat-demuxer list, quoting the path safely. */
export const concatListLine = (file: string): string => `file '${file.replace(/'/g, "'\\''")}'`;

type ProbeStream = {
  index: number;
  codec_type?: string;
  codec_name?: string;
  time_base?: string;
  disposition?: { attached_pic?: number };
};

const parseJson = <T>(text: string, what: string): T => {
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`could not read ${what}`);
  }
};

export const splitLosslessly = async (options: SplitOptions): Promise<LosslessSplit> => {
  const { input, chapters, outputDir, workDir, coverPath, childHooks } = options;
  const extension = path.extname(input).toLowerCase();
  // Every step reads or writes the whole file once; give each one ample time
  // for a long video on a busy disk.
  const timeoutMs = Math.max(600_000, Math.ceil((options.durationSeconds ?? 0) * 2000));
  const run = async (command: string, args: string[], what: string): Promise<SpawnResult> => {
    if (childHooks?.isStopped()) {
      throw new Error('interrupted by service shutdown');
    }
    const result = await runTracked(command, args, timeoutMs, childHooks);
    if (result.code !== 0) {
      throw new Error(`${what} failed: ${result.stderr.trim() || `exit code ${result.code ?? result.signal ?? 'unknown'}`}`);
    }
    return result;
  };

  await rm(workDir, { recursive: true, force: true });
  await mkdir(path.join(workDir, 'parts'), { recursive: true, mode: 0o750 });
  await mkdir(outputDir, { recursive: true, mode: 0o750 });
  try {
    // 1. The source's programme streams, their earliest timestamps and packet hashes.
    const probe = parseJson<{ streams?: ProbeStream[] }>(
      (
        await run(
          'ffprobe',
          ['-v', 'error', '-show_entries', 'stream=index,codec_type,codec_name,time_base:stream_disposition=attached_pic', '-of', 'json', input],
          'reading the source streams',
        )
      ).stdout,
      'the source streams',
    );
    const programme = (probe.streams ?? []).filter(
      (stream) => (stream.codec_type === 'video' && stream.disposition?.attached_pic !== 1) || stream.codec_type === 'audio',
    );
    // Same order as the `0:V? 0:a` mapping: video first, then audio.
    programme.sort((a, b) => Number(a.codec_type === 'audio') - Number(b.codec_type === 'audio') || a.index - b.index);
    if (!programme.some((stream) => stream.codec_type === 'audio')) {
      throw new Error('the source has no audio stream');
    }
    const packets = parseJson<{ packets?: { stream_index?: number; pts?: number }[] }>(
      (
        await run(
          'ffprobe',
          ['-v', 'error', '-read_intervals', '%+#256', '-show_entries', 'packet=stream_index,pts', '-of', 'json', input],
          'reading the source timestamps',
        )
      ).stdout,
      'the source timestamps',
    );
    const sourceHashes = parseStreamHashes((await run('ffmpeg', buildStreamHashArgs(['-i', input]), 'hashing the source')).stdout);
    if (sourceHashes.length !== programme.length) {
      throw new Error(`hashed ${sourceHashes.length} source streams instead of ${programme.length}`);
    }
    const streams: SplitStream[] = programme.map((stream, position) => {
      const starts = (packets.packets ?? [])
        .filter((packet) => packet.stream_index === stream.index && typeof packet.pts === 'number')
        .map((packet) => packet.pts as number);
      if (starts.length === 0) {
        throw new Error(`stream ${stream.index} has no timestamped packets`);
      }
      return {
        type: stream.codec_type as 'video' | 'audio',
        codec: stream.codec_name ?? 'unknown',
        timeBase: stream.time_base ?? '1/1000',
        startPts: Math.min(...starts),
        packetMd5: sourceHashes[position],
      };
    });

    // 2. Cut at the chapter starts without touching the coded data.
    const listFile = path.join(workDir, 'segments.csv');
    await run('ffmpeg', buildSegmentArgs(input, chapters, listFile, path.join(workDir, 'parts', `%05d${extension}`)), 'splitting the chapters');
    const segments = parseSegmentList(await readFile(listFile, 'utf8'));
    if (segments.length !== chapters.length) {
      throw new Error(`the split produced ${segments.length} files for ${chapters.length} chapters`);
    }

    // 3. Name, tag and decorate each chapter; streams are copied, never re-encoded.
    const parts: SplitPart[] = [];
    for (const [position, segment] of segments.entries()) {
      const chapter = chapters[position];
      const file = path.join(outputDir, chapterFileName(chapter, chapters.length, extension));
      await run(
        'ffmpeg',
        buildChapterFinishArgs(path.join(workDir, 'parts', path.basename(segment.name)), file, chapter, chapters.length, coverPath),
        `finishing chapter ${chapter.index}`,
      );
      parts.push({ chapter, file, start: segment.start, end: segment.end });
    }

    // 4. The chapter files, read back to back, must hold the source's packets exactly.
    const concatList = path.join(workDir, 'chapters.txt');
    await writeFile(concatList, `${parts.map((part) => concatListLine(part.file)).join('\n')}\n`, { mode: 0o640 });
    const joinedHashes = parseStreamHashes(
      (
        await run(
          'ffmpeg',
          buildStreamHashArgs(['-auto_convert', '0', '-f', 'concat', '-safe', '0', '-i', concatList], streams.length),
          'verifying the chapters',
        )
      ).stdout,
    );
    if (joinedHashes.join() !== sourceHashes.join()) {
      throw new Error('the chapter files do not add up to the original packets');
    }
    return { extension, streams, parts };
  } catch (error) {
    await rm(outputDir, { recursive: true, force: true });
    throw error;
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
};

const runTracked = async (
  command: string,
  args: string[],
  timeoutMs: number,
  childHooks?: Pick<ChildHooks, 'onSpawn' | 'onExit'>,
): Promise<SpawnResult> => {
  let spawned: ChildProcess | undefined;
  try {
    return await runCommand(command, args, {
      timeoutMs,
      onSpawn: (child) => {
        spawned = child;
        childHooks?.onSpawn(child);
      },
    });
  } finally {
    if (spawned) {
      childHooks?.onExit(spawned);
    }
  }
};
