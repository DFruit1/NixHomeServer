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
    const events = await db.query<{ event_type: string }>('select event_type from job_events where job_id = \'job-1\' order by id;');
    expect(events.map((event) => event.event_type)).toEqual(['queued', 'running']);
    db.close();
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
    }, 'dsaw');

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
    }, 'dsaw');

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

    const duplicate = await db.findCompletedDownload(request, 'dsaw');

    expect(duplicate).toBeUndefined();
  });

  it('isolates listing, duplicate detection, lookup, deletion, and history clearing by creator', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'alice-job', createdBy: 'alice', request });
    await db.setStatus('alice-job', 'completed');
    await db.createJob({ id: 'bob-job', createdBy: 'bob', request });
    await db.setStatus('bob-job', 'completed');

    expect((await db.listJobs('alice')).map((job) => job.id)).toEqual(['alice-job']);
    await expect(db.getJobForUser('bob-job', 'alice')).resolves.toBeUndefined();
    await expect(db.findCompletedDownload(request, 'alice')).resolves.toMatchObject({ id: 'alice-job' });
    await db.deleteJob('bob-job', 'alice');
    await expect(db.getJob('bob-job')).resolves.toBeDefined();
    await db.clearHistory('alice');
    await expect(db.getJob('alice-job')).resolves.toBeUndefined();
    await expect(db.getJob('bob-job')).resolves.toBeDefined();
    db.close();
  });

  it('atomically claims each queued job at most once', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'job-1', createdBy: 'alice', request });
    await db.createJob({ id: 'job-2', createdBy: 'alice', request });

    const claims = await Promise.all([db.claimNextQueuedJob(), db.claimNextQueuedJob(), db.claimNextQueuedJob()]);
    expect(claims.filter(Boolean).map((job) => job?.id).sort()).toEqual(['job-1', 'job-2']);
    await expect(db.queuedJobs()).resolves.toEqual([]);
    db.close();
  });

  it('drains terminal event retention backlogs larger than one batch', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'job-1', createdBy: 'alice', request });
    await db.setStatus('job-1', 'completed');
    await db.exec(`
      with recursive sequence(value) as (
        select 1
        union all
        select value + 1 from sequence where value < 10025
      )
      insert into job_events(job_id, created_at, event_type, message, data_json)
      select 'job-1', datetime('now', '-100 days'), 'old-event', cast(value as text), null
      from sequence;
    `);

    expect(await db.pruneEvents(90)).toBe(10025);
    const oldEvents = await db.query<{ count: number }>("select count(*) as count from job_events where event_type = 'old-event';");
    expect(oldEvents[0]?.count).toBe(0);
    db.close();
  });
});
