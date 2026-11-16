import type { ChildProcess } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { runCommand, type SpawnResult } from './child.js';
import { sanitizeSegment } from './paths.js';
import { buildRestoreFile, hashFileInto, parsePacketList, rebuiltSha256, sha256File } from './restore-data.js';
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
 * Lossless, reversible chapter splitting.
 *
 * Nothing is re-encoded. ffmpeg's segment muxer copies the coded packets of
 * the source into one file per chapter, so every packet lands in exactly one
 * chapter file. Two things are then proven before the split is used:
 *
 * 1. Each stream's raw data (its packets end to end) read from the chapter
 *    files in order has the same SHA-256 as the source's. No audio or video
 *    is lost, duplicated or reordered.
 * 2. A restore file (`restore-data.ts`) holding the source's container bytes
 *    and the place of every run of stream data rebuilds the source from that
 *    raw data byte for byte, with the source's SHA-256. Joining the chapters
 *    later therefore gives back the identical file: same timestamps, tags,
 *    cover and index, not merely the same decoded sound and picture.
 *
 * Packets cannot be cut in half, so a chapter boundary moves to the nearest
 * packet at or after the chapter's start: within a few milliseconds for audio,
 * and to the next keyframe (usually under a few seconds) for video. The cut
 * points actually used, and each chapter's share of every stream, are
 * recorded per chapter file.
 *
 * A chapter file is a new container around the same packets: its timestamps
 * start again at zero, it carries its own title and track tags, and the first
 * chapter loses any encoder-delay trim (AAC in MP4/M4A starts with ~21 ms of
 * decoder warm-up). None of that is carried back: a join rebuilds the
 * original from the restore file, and ignores the chapters' own containers.
 */

/** One coded stream of the source, as needed to recombine and verify it. */
export type SplitStream = {
  type: 'video' | 'audio';
  codec: string;
  /** Rational time base of `startPts`, e.g. `1/48000`. */
  timeBase: string;
  /** The stream's earliest presentation timestamp in the source. */
  startPts: number;
  /** Length and SHA-256 of the stream's raw data (its packets end to end). */
  bytes: number;
  sha256: string;
};

export type SplitPart = {
  chapter: Chapter;
  file: string;
  /** Where the chapter file actually starts and ends in the source, in seconds. */
  start: number;
  end: number;
  /** This chapter's share of each stream's raw data, in programme order. */
  streams: { bytes: number; sha256: string }[];
};

export type LosslessSplit = {
  extension: string;
  /** The file the chapters were cut from. */
  original: { name: string; bytes: number; sha256: string };
  streams: SplitStream[];
  parts: SplitPart[];
  /** The verified restore file, left at `SplitOptions.restoreFile`. */
  restore: { file: string; bytes: number; sha256: string };
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
  /** Where to write the restore file; it must not exist yet. */
  restoreFile: string;
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
 * Write the raw data of the given streams of `input` (their packets end to
 * end, no container) to one file each, in a single pass.
 */
export const buildDumpArgs = (input: string, streamSpecifiers: string[], outputs: string[]): string[] => [
  '-nostdin',
  '-hide_banner',
  '-v',
  'error',
  '-y',
  '-i',
  input,
  ...streamSpecifiers.flatMap((specifier, index) => ['-map', `0:${specifier}`, '-c', 'copy', '-f', 'data', outputs[index]]),
];

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
    // 1. The source's programme streams and their earliest timestamps.
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
    const firstPackets = parseJson<{ packets?: { stream_index?: number; pts?: number }[] }>(
      (
        await run(
          'ffprobe',
          ['-v', 'error', '-read_intervals', '%+#256', '-show_entries', 'packet=stream_index,pts', '-of', 'json', input],
          'reading the source timestamps',
        )
      ).stdout,
      'the source timestamps',
    );

    // 2. The source itself, and the raw data of each of its streams.
    const original = await sha256File(input);
    const sourceDumps = programme.map((_, position) => path.join(workDir, `source.${position}.bin`));
    await run(
      'ffmpeg',
      buildDumpArgs(
        input,
        programme.map((stream) => String(stream.index)),
        sourceDumps,
      ),
      'reading the source streams',
    );
    const sourceData = await Promise.all(sourceDumps.map((file) => sha256File(file)));
    const streams: SplitStream[] = programme.map((stream, position) => {
      const starts = (firstPackets.packets ?? [])
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
        bytes: sourceData[position].bytes,
        sha256: sourceData[position].sha256,
      };
    });

    // 3. Cut at the chapter starts without touching the coded data.
    const listFile = path.join(workDir, 'segments.csv');
    await run('ffmpeg', buildSegmentArgs(input, chapters, listFile, path.join(workDir, 'parts', `%05d${extension}`)), 'splitting the chapters');
    const segments = parseSegmentList(await readFile(listFile, 'utf8'));
    if (segments.length !== chapters.length) {
      throw new Error(`the split produced ${segments.length} files for ${chapters.length} chapters`);
    }

    // 4. Name, tag and decorate each chapter; streams are copied, never re-encoded.
    const parts: SplitPart[] = [];
    for (const [position, segment] of segments.entries()) {
      const chapter = chapters[position];
      const file = path.join(outputDir, chapterFileName(chapter, chapters.length, extension));
      await run(
        'ffmpeg',
        buildChapterFinishArgs(path.join(workDir, 'parts', path.basename(segment.name)), file, chapter, chapters.length, coverPath),
        `finishing chapter ${chapter.index}`,
      );
      parts.push({ chapter, file, start: segment.start, end: segment.end, streams: [] });
    }
    await rm(path.join(workDir, 'parts'), { recursive: true, force: true });

    // 5. The finished chapter files, read in order, must hold each stream's
    //    raw data exactly. A chapter keeps the programme streams first, so
    //    they are addressed by position (a cover comes after them).
    const running = programme.map(() => createHash('sha256'));
    for (const part of parts) {
      const chapterDumps = programme.map((_, position) => path.join(workDir, `chapter.${position}.bin`));
      await run(
        'ffmpeg',
        buildDumpArgs(
          part.file,
          programme.map((_, position) => String(position)),
          chapterDumps,
        ),
        `reading chapter ${part.chapter.index}`,
      );
      for (const [position, dump] of chapterDumps.entries()) {
        const own = createHash('sha256');
        const bytes = await hashFileInto(dump, [own, running[position]]);
        part.streams.push({ bytes, sha256: own.digest('hex') });
        await rm(dump, { force: true });
      }
    }
    for (const [position, hash] of running.entries()) {
      if (hash.digest('hex') !== streams[position].sha256) {
        throw new Error('the chapter files do not add up to the original audio and video data');
      }
    }

    // 6. Save what the chapters do not hold (the source's container), and
    //    prove that it and the stream data rebuild the source byte for byte.
    const packetList = parsePacketList(
      (
        await run(
          'ffprobe',
          ['-v', 'error', '-show_entries', 'packet=stream_index,pos,size', '-of', 'csv=p=0:nk=0', input],
          'reading the source packets',
        )
      ).stdout,
      programme.map((stream) => stream.index),
    );
    await buildRestoreFile({
      original: input,
      originalSha256: original.sha256,
      dumps: sourceDumps.map((file, position) => ({ file, ...sourceData[position] })),
      packets: packetList,
      output: options.restoreFile,
    });
    const rebuilt = await rebuiltSha256(options.restoreFile, sourceDumps);
    if (rebuilt.sha256 !== original.sha256 || rebuilt.bytes !== original.bytes) {
      throw new Error('the restore file does not rebuild the original exactly');
    }
    const restore = await sha256File(options.restoreFile);
    return {
      extension,
      original: { name: path.basename(input), ...original },
      streams,
      parts,
      restore: { file: options.restoreFile, ...restore },
    };
  } catch (error) {
    await rm(outputDir, { recursive: true, force: true });
    await rm(options.restoreFile, { force: true });
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
