import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../db.js';
import type { CreateJobRequest } from '../../shared/types.js';

let tempDir = '';

const request: CreateJobRequest = {
  url: 'https://example.test/watch?v=1',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'flac',
  splitChapters: false,
  includeChannel: true,
  includeDate: true,
};

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('sqlite state', () => {
  it('migrates and persists jobs', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    const columns = await db.query<{ name: string }>(`select name from pragma_table_info('jobs');`);
    expect(columns.map((column) => column.name)).toContain('alert_json');
    await db.createJob({ id: 'job-1', createdBy: 'dsaw', request });
    await db.setStatus('job-1', 'running');
    await db.markInterrupted();
    const job = await db.getJob('job-1');
    expect(job?.status).toBe('failed');
    expect(job?.error).toBe('interrupted by service restart');
  });

  it('finds completed duplicates by normalized URL and media type', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({
      id: 'job-1',
      createdBy: 'dsaw',
      request: {
        ...request,
        url: 'https://www.youtube.com/watch?si=abc&v=fiwd5hMQsEU&list=RDfiwd5hMQsEU',
      },
    });
    await db.setStatus('job-1', 'completed');

    const duplicate = await db.findCompletedDownload({
      ...request,
      url: 'https://www.youtube.com/watch?v=fiwd5hMQsEU',
    });

    expect(duplicate?.id).toBe('job-1');
  });

  it('does not treat audio and video downloads as duplicates of each other', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'job-1', createdBy: 'dsaw', request });
    await db.setStatus('job-1', 'completed');

    const duplicate = await db.findCompletedDownload({
      ...request,
      mediaType: 'video',
      audioFormat: undefined,
      videoContainer: 'mkv',
      videoQuality: '1080p',
    });

    expect(duplicate).toBeUndefined();
  });

  it('ignores incomplete or unsuccessful jobs when finding duplicates', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'failed-job', createdBy: 'dsaw', request });
    await db.setStatus('failed-job', 'failed', 'failed');
    await db.createJob({
      id: 'alert-job',
      createdBy: 'dsaw',
      request,
      initialStatus: 'alert',
      alert: { kind: 'duplicate', message: 'duplicate' },
    });

    const duplicate = await db.findCompletedDownload(request);

    expect(duplicate).toBeUndefined();
  });
});
