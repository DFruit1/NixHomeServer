import { spawnSync } from 'node:child_process';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { concatListLine, parseSegmentList, parseStreamHashes, segmentTimes, splitLosslessly, type LosslessSplit } from '../chapter-split.js';
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

  it('reads the segment list and stream hashes ffmpeg writes', () => {
    expect(parseSegmentList('00000.flac,0.000000,2.368000\n00001.flac,2.368000,4.608000\n')).toEqual([
      { name: '00000.flac', start: 0, end: 2.368 },
      { name: '00001.flac', start: 2.368, end: 4.608 },
    ]);
    expect(parseStreamHashes('0,v,MD5=0123456789abcdef0123456789abcdef\n1,a,MD5=fedcba9876543210fedcba9876543210\n')).toEqual([
      '0123456789abcdef0123456789abcdef',
      'fedcba9876543210fedcba9876543210',
    ]);
  });

  it('quotes apostrophes in concat list paths', () => {
    expect(concatListLine("/tmp/02 - It's Main.flac")).toBe("file '/tmp/02 - It'\\''s Main.flac'");
  });
});

/*
 * The guarantee the library relies on: a chapter split loses nothing, so the
 * chapters joined back (as Media Manager will) decode to exactly the original
 * samples and frames. Checked against real ffmpeg for every container the
 * downloader produces, including AAC's encoder-delay trim in MP4/M4A.
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
  const decodedHash = (file: string, stream: 'a' | 'V'): string => ffmpeg(['-i', file, '-map', `0:${stream}`, '-f', 'hash', '-hash', 'md5', '-']).trim();

  beforeAll(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-split-'));
    const audio = ['-f', 'lavfi', '-i', 'sine=f=440:d=6', '-f', 'lavfi', '-i', 'anoisesrc=d=6:a=0.05', '-filter_complex', 'amix=inputs=2', '-ac', '2', '-ar', '48000'];
    ffmpeg([...audio, '-c:a', 'flac', path.join(dir, 'source.flac')]);
    ffmpeg([...audio, '-c:a', 'pcm_s16le', path.join(dir, 'source.wav')]);
    ffmpeg([...audio, '-c:a', 'aac', '-b:a', '128k', path.join(dir, 'source.m4a')]);
    ffmpeg([...audio, '-c:a', 'libmp3lame', '-q:a', '4', path.join(dir, 'source.mp3')]);
    ffmpeg([...audio, '-c:a', 'libopus', '-b:a', '96k', path.join(dir, 'source.opus')]);
    const video = ['-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=6', '-f', 'lavfi', '-i', 'sine=f=440:d=6'];
    ffmpeg([...video, '-c:v', 'libx264', '-g', '25', '-c:a', 'aac', path.join(dir, 'source.mkv')]);
    ffmpeg([...video, '-c:v', 'libx264', '-g', '25', '-c:a', 'aac', path.join(dir, 'source.mp4')]);
    ffmpeg([...video, '-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-g', '25', '-c:a', 'libopus', path.join(dir, 'source.webm')]);
    ffmpeg(['-f', 'lavfi', '-i', 'color=red:s=64x64', '-frames:v', '1', path.join(dir, 'cover.jpg')]);
  }, 120_000);

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  /** Join the chapters back the way Media Manager does: concat, then restore each stream's start. */
  const recombine = async (split: LosslessSplit, output: string): Promise<void> => {
    const list = path.join(path.dirname(output), 'join.txt');
    await writeFile(list, `${split.parts.map((part) => concatListLine(part.file)).join('\n')}\n`);
    const firstPts = (stream: number): number => {
      const probe = spawnSync(
        'ffprobe',
        ['-v', 'error', '-read_intervals', '%+#256', '-select_streams', String(stream), '-show_entries', 'packet=pts', '-of', 'csv=p=0', split.parts[0].file],
        { encoding: 'utf8' },
      );
      return Math.min(...probe.stdout.split('\n').filter((line) => /^-?\d+$/.test(line.trim())).map(Number));
    };
    const seconds = (pts: number, timeBase: string): number => {
      const [num, den] = timeBase.split('/').map(Number);
      return (pts * num) / den;
    };
    const inputs: string[] = [];
    const maps: string[] = [];
    split.streams.forEach((stream, index) => {
      // Chapter files keep the programme streams in the same order, first.
      const chapterTimeBase = spawnSync(
        'ffprobe',
        ['-v', 'error', '-select_streams', String(index), '-show_entries', 'stream=time_base', '-of', 'csv=p=0', split.parts[0].file],
        { encoding: 'utf8' },
      ).stdout.trim();
      const offset = seconds(stream.startPts, stream.timeBase) - seconds(firstPts(index), chapterTimeBase);
      inputs.push('-auto_convert', '0', '-itsoffset', offset.toFixed(6), '-f', 'concat', '-safe', '0', '-i', list);
      maps.push('-map', `${index}:${index}`);
    });
    ffmpeg([...inputs, ...maps, '-c', 'copy', output]);
  };

  for (const extension of ['.flac', '.wav', '.m4a', '.mp3', '.opus', '.mkv', '.mp4', '.webm']) {
    it(`splits ${extension} without loss and joins back to the identical decode`, async () => {
      const source = path.join(dir, `source${extension}`);
      const work = await mkdtemp(path.join(dir, 'case-'));
      const split = await splitLosslessly({
        input: source,
        chapters,
        outputDir: path.join(work, 'chapters'),
        workDir: path.join(work, 'work'),
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

      const joined = path.join(work, `joined${extension}`);
      await recombine(split, joined);
      expect(decodedHash(joined, 'a')).toBe(decodedHash(source, 'a'));
      if (['.mkv', '.mp4', '.webm'].includes(extension)) {
        expect(decodedHash(joined, 'V')).toBe(decodedHash(source, 'V'));
      }
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
      }),
    ).rejects.toThrow(/2 chapters/);
    await expect(readdir(path.join(work, 'chapters'))).rejects.toThrow();
  });
});
