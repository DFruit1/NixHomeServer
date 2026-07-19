import { createServer, type Server } from 'node:http';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import { handleRequest } from '../http.js';
import type { JobQueue } from '../queue.js';
import type { CreateJobRequest } from '../../shared/types.js';

let tempDir = '';
let db: Database;
let server: Server;
let baseUrl = '';

const request: CreateJobRequest = {
  url: 'https://www.youtube.com/watch?v=fiwd5hMQsEU',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'flac',
  splitChapters: false,
  includeChannel: true,
  includeDate: true,
  ytDlpVersion: 'packaged',
};

const authHeaders = (username: string): Record<string, string> => ({
  'x-forwarded-preferred-username': username,
  'x-forwarded-groups': 'downloads-users',
});

const mutationHeaders = (username: string, origin = baseUrl): Record<string, string> => ({
  ...authHeaders(username),
  origin,
  'content-type': 'application/json',
});

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-http-test-'));
  const config: AppConfig = {
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
    sharedRoot: path.join(tempDir, 'shared'),
    concurrency: 1,
    sharedWriteGroup: 'files-shared-users',
    fileBrowserSharedMountName: '_Shared',
    eventRetentionDays: 90,
  };
  db = new Database(config.databasePath);
  await db.migrate();
  const queue = {} as JobQueue;
  server = createServer((incoming, outgoing) => {
    void handleRequest({ config, db, queue }, incoming, outgoing);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('test server did not bind');
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterEach(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  db.close();
  await rm(tempDir, { recursive: true, force: true });
});

describe('authenticated job APIs', () => {
  it('does not expose or mutate another user’s jobs', async () => {
    await db.createJob({ id: 'alice-job', createdBy: 'alice', request });
    await db.setStatus('alice-job', 'completed');
    await db.createJob({ id: 'bob-job', createdBy: 'bob', request });
    await db.setStatus('bob-job', 'completed');

    const listResponse = await fetch(`${baseUrl}/api/jobs`, { headers: authHeaders('alice') });
    expect(listResponse.status).toBe(200);
    const listedJobs = (await listResponse.json()) as Array<{ id: string }>;
    expect(listedJobs.map((job) => job.id)).toEqual(['alice-job']);

    const crossUserRead = await fetch(`${baseUrl}/api/jobs/bob-job`, { headers: authHeaders('alice') });
    expect(crossUserRead.status).toBe(404);
    const crossUserDelete = await fetch(`${baseUrl}/api/jobs/bob-job`, {
      method: 'DELETE',
      headers: mutationHeaders('alice'),
      body: '{}',
    });
    expect(crossUserDelete.status).toBe(404);
    await expect(db.getJob('bob-job')).resolves.toBeDefined();

    const clearResponse = await fetch(`${baseUrl}/api/jobs`, {
      method: 'DELETE',
      headers: mutationHeaders('alice'),
      body: '{}',
    });
    expect(clearResponse.status).toBe(204);
    await expect(db.getJob('alice-job')).resolves.toBeUndefined();
    await expect(db.getJob('bob-job')).resolves.toBeDefined();
  });

  it('rejects API requests without a trusted authentication header', async () => {
    const response = await fetch(`${baseUrl}/api/jobs`);
    expect(response.status).toBe(401);
  });

  it.each([
    ['POST', '/api/probe'],
    ['POST', '/api/jobs'],
    ['DELETE', '/api/jobs'],
    ['POST', '/api/jobs/example/cancel'],
    ['POST', '/api/jobs/example/retry'],
    ['POST', '/api/jobs/example/resolve-alert'],
    ['DELETE', '/api/jobs/example'],
  ])('rejects sibling-origin %s mutations at %s', async (method, route) => {
    const response = await fetch(`${baseUrl}${route}`, {
      method,
      headers: mutationHeaders('alice', 'http://homepage.example.test'),
      body: '{}',
    });

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toMatchObject({ error: expect.stringMatching(/origin|same-origin/) });
  });

  it('requires JSON and rejects oversized mutation bodies', async () => {
    const wrongType = await fetch(`${baseUrl}/api/jobs`, {
      method: 'POST',
      headers: { ...authHeaders('alice'), origin: baseUrl, 'content-type': 'text/plain' },
      body: '{}',
    });
    expect(wrongType.status).toBe(415);

    const oversized = await fetch(`${baseUrl}/api/jobs`, {
      method: 'POST',
      headers: mutationHeaders('alice'),
      body: JSON.stringify({ padding: 'x'.repeat(70 * 1024) }),
    });
    expect(oversized.status).toBe(413);
  });

  it('requires an Origin and rejects a mismatched forwarded protocol', async () => {
    const missingOrigin = await fetch(`${baseUrl}/api/jobs`, {
      method: 'POST',
      headers: { ...authHeaders('alice'), 'content-type': 'application/json' },
      body: '{}',
    });
    expect(missingOrigin.status).toBe(403);

    const protocolMismatch = await fetch(`${baseUrl}/api/jobs`, {
      method: 'POST',
      headers: { ...mutationHeaders('alice'), 'x-forwarded-proto': 'https' },
      body: '{}',
    });
    expect(protocolMismatch.status).toBe(403);
  });

  it('rejects non-object JSON bodies before routing a mutation', async () => {
    for (const body of ['null', '[]', '"text"']) {
      const response = await fetch(`${baseUrl}/api/jobs`, {
        method: 'POST',
        headers: mutationHeaders('alice'),
        body,
      });
      expect(response.status).toBe(400);
    }
  });

  it('serves a recorded cover but never follows a symlink in its output path', async () => {
    const output = path.join(tempDir, 'output');
    const outside = path.join(tempDir, 'outside.jpg');
    await mkdir(output, { recursive: true });
    await writeFile(outside, 'private image');
    await writeFile(path.join(output, 'cover.jpg'), 'safe image');
    await db.createJob({ id: 'cover-job', createdBy: 'alice', request });
    await db.setOutput('cover-job', output, output);
    await db.addFile('cover-job', 'cover.jpg', 'cover');
    await db.setStatus('cover-job', 'completed');

    const safe = await fetch(`${baseUrl}/api/jobs/cover-job/files/0`, { headers: authHeaders('alice') });
    expect(safe.status).toBe(200);
    await expect(safe.text()).resolves.toBe('safe image');

    await rm(path.join(output, 'cover.jpg'));
    await symlink(outside, path.join(output, 'cover.jpg'));
    const linked = await fetch(`${baseUrl}/api/jobs/cover-job/files/0`, { headers: authHeaders('alice') });
    expect(linked.status).toBe(404);
    await expect(linked.text()).resolves.not.toContain('private image');
  });

  it('rejects symlinked ancestor folders and reports stale file records as missing', async () => {
    const output = path.join(tempDir, 'nested-output');
    const outside = path.join(tempDir, 'outside-folder');
    await mkdir(output, { recursive: true });
    await mkdir(outside, { recursive: true });
    await writeFile(path.join(outside, 'cover.jpg'), 'private nested image');
    await symlink(outside, path.join(output, 'linked-folder'));

    await db.createJob({ id: 'nested-link-job', createdBy: 'alice', request });
    await db.setOutput('nested-link-job', output, output);
    await db.addFile('nested-link-job', 'linked-folder/cover.jpg', 'cover');
    await db.setStatus('nested-link-job', 'completed');

    const linked = await fetch(`${baseUrl}/api/jobs/nested-link-job/files/0`, { headers: authHeaders('alice') });
    expect(linked.status).toBe(404);
    await expect(linked.text()).resolves.not.toContain('private nested image');

    await db.createJob({ id: 'stale-file-job', createdBy: 'alice', request });
    await db.setOutput('stale-file-job', output, output);
    await db.addFile('stale-file-job', 'missing.jpg', 'cover');
    await db.setStatus('stale-file-job', 'completed');

    const stale = await fetch(`${baseUrl}/api/jobs/stale-file-job/files/0`, { headers: authHeaders('alice') });
    expect(stale.status).toBe(404);
  });
});
