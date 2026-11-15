import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  ITEM_METADATA_FOLDER,
  archiveThumbnail,
  buildItemManifest,
  prepareItemMetadataFolder,
  writeItemManifest,
} from '../item-manifest.js';
import type { CreateJobRequest, ProbeResponse } from '../../shared/types.js';

const source: ProbeResponse = {
  title: 'Live Set: Part / One',
  id: 'abcdefghijk',
  channel: 'Some Artist',
  channelId: 'UC0123456789012345678901',
  uploadDate: '20250102',
  durationSeconds: 300,
  chapters: [
    { index: 1, title: 'Intro', startTime: 0 },
    { index: 2, title: 'Main', startTime: 60, endTime: 240 },
    { index: 3, title: 'Outro', startTime: 240 },
  ],
  isPlaylist: false,
};

const request: CreateJobRequest = {
  url: 'https://www.youtube.com/watch?v=abcdefghijk',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'opus',
  splitChapters: false,
  embedAudioCoverArt: false,
  includeChannel: true,
  includeDate: false,
  ytDlpVersion: 'packaged',
  chaptersConfirmed: true,
};

const root = '/library/_Music/_YouTube';

describe('buildItemManifest', () => {
  it('keeps the chapter list of an unsplit file and resolves every end time', () => {
    const manifest = buildItemManifest({
      jobId: 'job-1',
      downloadedBy: 'someone',
      downloadedAt: '2026-11-16T00:00:00.000Z',
      request,
      source,
      itemFolder: `${root}/Some Artist`,
      files: [`${root}/Some Artist/Live Set Part One.opus`, `${root}/Some Artist/Live Set Part One.info.json`],
      hasThumbnail: true,
    });

    expect(manifest.chapters).toEqual([
      { index: 1, title: 'Intro', startTime: 0, endTime: 60 },
      { index: 2, title: 'Main', startTime: 60, endTime: 240 },
      { index: 3, title: 'Outro', startTime: 240, endTime: 300 },
    ]);
    expect(manifest.state).toEqual({ split: false, coverEmbedded: false });
    expect(manifest.original).toBeUndefined();
    expect(manifest.files).toEqual([
      { path: 'Live Set Part One.info.json', role: 'info-json' },
      { path: 'Live Set Part One.opus', role: 'media' },
    ]);
    expect(manifest.naming).toEqual({ title: 'Live Set Part One', channel: 'Some Artist', date: '2025-01-02', year: '2025' });
    // One-shot confirmations are not options the media app can flip.
    expect(manifest.download.options).not.toHaveProperty('chaptersConfirmed');
  });

  it('maps each chapter file of a split to its chapter and cut points', () => {
    const folder = `${root}/Some Artist/Live Set Part One`;
    const part = (index: number, start: number, end: number) => ({ chapter: source.chapters[index - 1], file: '', start, end });
    const manifest = buildItemManifest({
      jobId: 'job-2',
      downloadedBy: 'someone',
      downloadedAt: '2026-11-16T00:00:00.000Z',
      request: { ...request, mediaType: 'video', videoContainer: 'mkv', videoQuality: 'best', splitChapters: true },
      source,
      split: {
        extension: '.mkv',
        streams: [{ type: 'video', codec: 'h264', timeBase: '1/1000', startPts: 0, packetMd5: '0'.repeat(32) }],
        parts: [part(1, 0, 61.2), part(2, 61.2, 241.6), part(3, 241.6, 300)],
      },
      itemFolder: folder,
      files: [`${folder}/03 - Outro.mkv`, `${folder}/01 - Intro.mkv`, `${folder}/video.nfo`, `${folder}/poster.jpg`, `${folder}/02 - Main.mkv`],
      hasThumbnail: true,
    });

    expect(manifest.files.filter((file) => file.role === 'chapter')).toEqual([
      { path: '01 - Intro.mkv', role: 'chapter', chapter: 1, start: 0, end: 61.2 },
      { path: '02 - Main.mkv', role: 'chapter', chapter: 2, start: 61.2, end: 241.6 },
      { path: '03 - Outro.mkv', role: 'chapter', chapter: 3, start: 241.6, end: 300 },
    ]);
    // Video chapters rely on the folder poster rather than an embedded cover.
    expect(manifest.state).toEqual({ split: true, coverEmbedded: false });
    expect(manifest.original).toMatchObject({ extension: '.mkv', method: 'stream-copy' });
  });
});

describe('item metadata folder', () => {
  let dir = '';

  beforeEach(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-manifest-'));
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('gives a second download of the same video in one folder its own manifest and thumbnail', async () => {
    const thumbnail = path.join(dir, 'thumb.jpg');
    await writeFile(thumbnail, 'jpeg');
    for (const jobId of ['first', 'second']) {
      const reserved = await prepareItemMetadataFolder(dir, 'abcdefghijk');
      await archiveThumbnail(thumbnail, reserved.folder, reserved.stem);
      await writeItemManifest(reserved.folder, reserved.stem, { download: { jobId } } as never);
    }

    const folder = path.join(dir, ITEM_METADATA_FOLDER);
    expect((await readdir(folder)).sort()).toEqual([
      '.nomedia',
      'abcdefghijk (1).jpg',
      'abcdefghijk (1).json',
      'abcdefghijk.jpg',
      'abcdefghijk.json',
    ]);
    expect(JSON.parse(await readFile(path.join(folder, 'abcdefghijk (1).json'), 'utf8')).download.jobId).toBe('second');
  });
});
