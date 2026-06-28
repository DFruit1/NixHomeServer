import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import { JobQueue, audioChapterSpecs, buildAudioChapterFfmpegArgs, chapterGateFor, normalizeCreateJobRequest } from '../queue.js';
import type { CreateJobRequest, CurrentUser, ProbeResponse } from '../../shared/types.js';

let tempDir = '';

const request: CreateJobRequest = {
  url: 'https://www.youtube.com/watch?v=fiwd5hMQsEU',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'flac',
  splitChapters: false,
  includeChannel: true,
  includeDate: true,
};

const user: CurrentUser = {
  username: 'dsaw',
  groups: [],
  canWriteShared: true,
  destinations: ['personal', 'shared'],
};

const source = {
  title: 'Example',
  chapters: [],
  isPlaylist: false,
} satisfies ProbeResponse;

const config = (): AppConfig => ({
  host: '127.0.0.1',
  port: 0,
  stateDir: tempDir,
  databasePath: path.join(tempDir, 'state.sqlite'),
  tempRoot: path.join(tempDir, 'tmp'),
  staticDir: path.join(tempDir, 'static'),
  ytDlpPath: 'yt-dlp',
  sharedVideoRoot: path.join(tempDir, 'shared', 'videos'),
  sharedAudioRoot: path.join(tempDir, 'shared', 'audio'),
  sharedAudiobooksRoot: path.join(tempDir, 'shared', 'audiobooks'),
  usersRoot: path.join(tempDir, 'users'),
  concurrency: 0,
  sharedWriteGroup: 'files-shared-users',
});

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('queue alerts', () => {
  it('pauses duplicate jobs without queueing a worker-visible job', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'completed-job', createdBy: 'dsaw', request });
    await db.setStatus('completed-job', 'completed');

    const queue = new JobQueue(config(), db);
    const id = await queue.enqueue(user, { ...request, url: 'https://www.youtube.com/watch?si=abc&v=fiwd5hMQsEU' });

    const job = await db.getJob(id);
    expect(job?.status).toBe('alert');
    expect(job?.alert?.kind).toBe('duplicate');
    expect(job?.alert?.duplicateJobId).toBe('completed-job');
    await expect(db.queuedJobs()).resolves.toEqual([]);
  });

  it('queues duplicate jobs after explicit confirmation', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'completed-job', createdBy: 'dsaw', request });
    await db.setStatus('completed-job', 'completed');

    const queue = new JobQueue(config(), db);
    const id = await queue.enqueue(user, request);
    await queue.resolveAlert(id, 'download-again');

    const job = await db.getJob(id);
    expect(job?.status).toBe('queued');
    expect(job?.request.duplicateConfirmed).toBe(true);
    expect(job?.alert).toBeUndefined();
  });

  it('identifies chapter confirmation and no-chapter downgrade cases', () => {
    expect(chapterGateFor({ ...request, splitChapters: false }, { ...source, chapters: [{ index: 1, title: 'Intro', startTime: 0 }] })).toBe(
      'alert',
    );
    expect(chapterGateFor({ ...request, splitChapters: true }, source)).toBe('single-file');
    expect(
      chapterGateFor(
        { ...request, splitChapters: false, chaptersConfirmed: true },
        { ...source, chapters: [{ index: 1, title: 'Intro', startTime: 0 }] },
      ),
    ).toBe('download');
  });

  it('defaults new requests to split chapters and embedded audio cover art', () => {
    expect(normalizeCreateJobRequest({ ...request, splitChapters: undefined as unknown as boolean })).toMatchObject({
      splitChapters: true,
      embedAudioCoverArt: true,
    });
    expect(
      normalizeCreateJobRequest({
        ...request,
        mediaType: 'video',
        audioFormat: undefined,
        videoContainer: 'mkv',
        videoQuality: '1080p',
        splitChapters: undefined as unknown as boolean,
      }),
    ).toMatchObject({
      splitChapters: true,
      embedAudioCoverArt: undefined,
    });
  });

  it('derives audio chapter durations from explicit and adjacent chapter boundaries', () => {
    expect(
      audioChapterSpecs({
        ...source,
        durationSeconds: 180,
        chapters: [
          { index: 1, title: 'One', startTime: 0, endTime: 60 },
          { index: 2, title: 'Two', startTime: 60 },
          { index: 3, title: 'Three', startTime: 125 },
        ],
      }).map(({ start, duration }) => ({ start, duration })),
    ).toEqual([
      { start: 0, duration: 60 },
      { start: 60, duration: 65 },
      { start: 125, duration: 55 },
    ]);
  });

  it('re-encodes split flac chapters so duration metadata is regenerated', () => {
    const args = buildAudioChapterFfmpegArgs({
      input: '/tmp/source.flac',
      output: '/tmp/01 - Intro.flac',
      chapter: { index: 1, title: 'Intro', startTime: 0, endTime: 30 },
      start: 0,
      duration: 30,
      audioFormat: 'flac',
    });

    expect(args).toContain('-t');
    expect(args).toContain('30.000');
    expect(args).toContain('flac');
    expect(args).not.toContain('copy');
    expect(args).toContain('-map_chapters');
    expect(args).toContain('-1');
  });

  it('embeds cover art into supported split audio chapter formats when a cover is available', () => {
    const args = buildAudioChapterFfmpegArgs({
      input: '/tmp/source.mp3',
      output: '/tmp/01 - Intro.mp3',
      chapter: { index: 1, title: 'Intro', startTime: 0, endTime: 30 },
      start: 0,
      duration: 30,
      audioFormat: 'mp3',
      coverPath: '/tmp/cover.jpg',
    });

    expect(args).toContain('/tmp/cover.jpg');
    expect(args).toContain('1:v:0');
    expect(args).toContain('attached_pic');
    expect(args).not.toContain('-vn');
  });

  it('omits cover art mapping for unsupported split audio chapter formats', () => {
    const args = buildAudioChapterFfmpegArgs({
      input: '/tmp/source.opus',
      output: '/tmp/01 - Intro.opus',
      chapter: { index: 1, title: 'Intro', startTime: 0, endTime: 30 },
      start: 0,
      duration: 30,
      audioFormat: 'opus',
      coverPath: '/tmp/cover.jpg',
    });

    expect(args).not.toContain('/tmp/cover.jpg');
    expect(args).not.toContain('1:v:0');
    expect(args).toContain('-vn');
  });
});
