import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import { JobQueue, chapterGateFor } from '../queue.js';
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
  usersRoot: path.join(tempDir, 'users'),
  concurrency: 0,
  sharedWriteGroup: 'shared-files-read-write-access',
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
});
