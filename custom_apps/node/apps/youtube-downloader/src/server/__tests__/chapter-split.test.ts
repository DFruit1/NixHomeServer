import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { appendFile, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildDumpArgs, concatListLine, parseSegmentList, segmentTimes, splitLosslessly, type LosslessSplit } from '../chapter-split.js';
import { parsePacketList, rebuildOriginal, sha256File } from '../restore-data.js';
import type { Chapter } from '../../shared/types.js';

const HAS_FFMPEG = spawnSync('ffmpeg', ['-version']).status === 0 && spawnSync('ffprobe', ['-version']).status === 0;

const chapters: Chapter[] = [
  { index: 1, title: 'Intro', startTime: 0 },
  { index: 2, title: "It's / Main", startTime: 2.35 },
  { index: 3, title: 'Outro', startTime: 4.6 },
];

describe('split helpers', () => {
  it('cuts after the first chapter, in ascending order only', () => {
    expect(segmentTimes(chapters)).toBe('2.350000,4.600000');
    expect(() => segmentTimes([chapters[0]])).toThrow(/two chapters/);
    expect(() => segmentTimes([chapters[0], { ...chapters[1], startTime: 0 }])).toThrow(/does not start after/);
  });

  it('reads the segment list and packet list ffmpeg writes', () => {
    expect(parseSegmentList('00000.flac,0.000000,2.368000\n00001.flac,2.368000,4.608000\n')).toEqual([
      { name: '00000.flac', start: 0, end: 2.368 },
      { name: '00001.flac', start: 2.368, end: 4.608 },
    ]);
    // Only the wanted streams, numbered by their place in the programme; a
    // packet without a position is looked for after its predecessor.
    expect(parsePacketList('stream_index=1,size=10,pos=100\nstream_index=2,size=5,pos=7\nstream_index=0,size=20\n', [0, 1])).toEqual({
      stream: [1, 0],
      size: [10, 20],
      pos: [100, -1],
    });
  });

  it('quotes apostrophes in concat list paths', () => {
    expect(concatListLine("/tmp/02 - It's Main.flac")).toBe("file '/tmp/02 - It'\\''s Main.flac'");
  });
});

/*
 * The guarantee the library relies on: a chapter split is reversible to the
 * byte. The chapters' stream data plus the restore file rebuild the original
 * file with the original's SHA-256 (as Media Manager does on a join), for
 * every container the downloader produces, and still do after a chapter file
 * has been re-tagged. Checked against real ffmpeg.
 */
describe.runIf(HAS_FFMPEG)('lossless split round trip', () => {
  let dir = '';
  const ffmpeg = (args: string[]): string => {
    const result = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', '-v', 'error', '-y', ...args], { encoding: 'utf8' });
    if (result.status !== 0) {
      throw new Error(result.stderr);
    }
    return result.stdout;
  };

  beforeAll(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-split-'));
    const audio = ['-f', 'lavfi', '-i', 'sine=f=440:d=6', '-f', 'lavfi', '-i', 'anoisesrc=d=6:a=0.05', '-filter_complex', 'amix=inputs=2', '-ac', '2', '-ar', '48000'];
    const tags = ['-metadata', 'title=Original Title', '-metadata', 'artist=Some Artist', '-metadata', 'comment=kept exactly'];
    ffmpeg([...audio, ...tags, '-c:a', 'flac', path.join(dir, 'source.flac')]);
    ffmpeg([...audio, '-c:a', 'pcm_s16le', path.join(dir, 'source.wav')]);
    ffmpeg([...audio, ...tags, '-c:a', 'aac', '-b:a', '128k', path.join(dir, 'source.m4a')]);
    ffmpeg([...audio, ...tags, '-c:a', 'libmp3lame', '-q:a', '4', path.join(dir, 'source.mp3')]);
    ffmpeg([...audio, ...tags, '-c:a', 'libopus', '-b:a', '96k', path.join(dir, 'source.opus')]);
    const video = ['-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=6', '-f', 'lavfi', '-i', 'sine=f=440:d=6'];
    ffmpeg([...video, ...tags, '-c:v', 'libx264', '-g', '25', '-c:a', 'aac', path.join(dir, 'source.mkv')]);
    ffmpeg([...video, ...tags, '-c:v', 'libx264', '-g', '25', '-c:a', 'aac', path.join(dir, 'source.mp4')]);
    ffmpeg([...video, '-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-g', '25', '-c:a', 'libopus', path.join(dir, 'source.webm')]);
    ffmpeg(['-f', 'lavfi', '-i', 'color=red:s=64x64', '-frames:v', '1', path.join(dir, 'cover.jpg')]);
  }, 120_000);

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  /** Each stream's raw data, read from the chapter files in order. */
  const chapterStreamData = async (split: LosslessSplit, work: string): Promise<string[]> => {
    const dumps = split.streams.map((_, position) => path.join(work, `joined.${position}.bin`));
    for (const part of split.parts) {
      const pieces = split.streams.map((_, position) => path.join(work, `piece.${position}.bin`));
      ffmpeg(
        buildDumpArgs(
          part.file,
          split.streams.map((_, position) => String(position)),
          pieces,
        ).slice(5),
      );
      for (const [position, piece] of pieces.entries()) {
        await appendFile(dumps[position], await readFile(piece));
      }
    }
    return dumps;
  };

  for (const extension of ['.flac', '.wav', '.m4a', '.mp3', '.opus', '.mkv', '.mp4', '.webm']) {
    it(`splits ${extension} and rebuilds the identical file from the chapters`, async () => {
      const source = path.join(dir, `source${extension}`);
      const work = await mkdtemp(path.join(dir, 'case-'));
      const split = await splitLosslessly({
        input: source,
        chapters,
        outputDir: path.join(work, 'chapters'),
        workDir: path.join(work, 'work'),
        restoreFile: path.join(work, 'split.restore'),
        coverPath: path.join(dir, 'cover.jpg'),
      });

      expect((await readdir(path.join(work, 'chapters'))).sort()).toEqual([
        `01 - Intro${extension}`,
        `02 - It's Main${extension}`,
        `03 - Outro${extension}`,
      ]);
      expect(split.parts.map((part) => part.chapter.index)).toEqual([1, 2, 3]);
      // Cuts land on the first packet or keyframe at or after the chapter start.
      expect(split.parts[1].start).toBeGreaterThanOrEqual(2.35 - 0.001);
      expect(split.parts[1].start).toBeLessThan(2.35 + 1.01);
      expect(split.parts[0].end).toBe(split.parts[1].start);
      // Every byte of every stream is in exactly one chapter.
      split.streams.forEach((stream, position) => {
        expect(split.parts.reduce((total, part) => total + part.streams[position].bytes, 0)).toBe(stream.bytes);
      });
      const original = await sha256File(source);
      expect(split.original).toEqual({ name: `source${extension}`, ...original });
      // The restore file holds the container, not the media.
      expect(split.restore.bytes).toBeLessThan(original.bytes * 0.1);

      // A chapter re-tagged later (new container, same packets) changes nothing.
      const retagged = path.join(work, `retagged${extension}`);
      ffmpeg(['-i', split.parts[1].file, '-map', '0', '-c', 'copy', '-metadata', 'title=Changed later', retagged]);
      await rename(retagged, split.parts[1].file);

      const rebuilt = path.join(work, `rebuilt${extension}`);
      const header = await rebuildOriginal(split.restore.file, await chapterStreamData(split, work), (chunk) => {
        appendFileSync(rebuilt, chunk);
      });
      expect(header.originalSha256).toBe(original.sha256);
      expect(await sha256File(rebuilt)).toEqual(original);
    }, 60_000);
  }

  it('refuses a split that would not have one file per chapter', async () => {
    const work = await mkdtemp(path.join(dir, 'case-'));
    await expect(
      splitLosslessly({
        input: path.join(dir, 'source.flac'),
        // Past the end of the six-second source: no packet to cut at.
        chapters: [chapters[0], { index: 2, title: 'Beyond', startTime: 60 }],
        outputDir: path.join(work, 'chapters'),
        workDir: path.join(work, 'work'),
        restoreFile: path.join(work, 'split.restore'),
      }),
    ).rejects.toThrow(/2 chapters/);
    await expect(readdir(path.join(work, 'chapters'))).rejects.toThrow();
    await expect(readFile(path.join(work, 'split.restore'))).rejects.toThrow();
  });
});
