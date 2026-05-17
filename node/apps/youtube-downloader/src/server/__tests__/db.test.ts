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
    await db.createJob({ id: 'job-1', createdBy: 'dsaw', request });
    await db.setStatus('job-1', 'running');
    await db.markInterrupted();
    const job = await db.getJob('job-1');
    expect(job?.status).toBe('failed');
    expect(job?.error).toBe('interrupted by service restart');
  });
});
