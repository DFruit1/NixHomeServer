import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import {
  JobQueue,
  audioChapterSpecs,
  buildAudioChapterFfmpegArgs,
  chapterGateFor,
  normalizeCreateJobRequest,
  validateDownloadUrl,
  ytDlpPathFor,
} from '../queue.js';
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
  sharedRoot: path.join(tempDir, 'shared'),
  concurrency: 0,
  sharedWriteGroup: 'files-shared-users',
  fileBrowserSharedMountName: '_Shared',
  eventRetentionDays: 90,
});

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('queue alerts', () => {
  it('refuses to start or claim new work after shutdown begins', async () => {
    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    const queue = new JobQueue({ ...config(), concurrency: 1 }, db);

    await queue.stop(0);

    await expect(queue.start()).rejects.toThrow(/shutting down/);
    await expect(queue.enqueue(user, request)).rejects.toThrow(/shutting down/);
    await expect(db.queuedJobs()).resolves.toEqual([]);
    db.close();
  });

  it('waits for TERM then KILL child exit before shutdown resolves', async () => {
    const marker = path.join(tempDir, 'child.pid');
    const termMarker = path.join(tempDir, 'child.term');
    const stubbornProbe = path.join(tempDir, 'stubborn-probe.mjs');
    await writeFile(
      stubbornProbe,
      `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, String(process.pid));\nprocess.on('SIGTERM', () => writeFileSync(${JSON.stringify(termMarker)}, 'term'));\nsetInterval(() => {}, 1000);\n`,
    );
    await chmod(stubbornProbe, 0o755);

    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({ id: 'stubborn-job', createdBy: user.username, request });
    const queue = new JobQueue({ ...config(), concurrency: 1, ytDlpPath: stubbornProbe }, db);
    await queue.start();
    await waitForFile(marker);

    await expect(queue.stop(75)).resolves.toBeUndefined();

    await expect(readFile(termMarker, 'utf8')).resolves.toBe('term');
    const childPid = Number(await readFile(marker, 'utf8'));
    expect(() => process.kill(childPid, 0)).toThrow();
    await expect(db.getJob('stubborn-job')).resolves.toMatchObject({
      status: 'failed',
      error: 'interrupted by service shutdown',
    });
    db.close();
  });

  it('waits for an in-flight queue claim before shutdown completes', async () => {
    let releaseClaim!: () => void;
    let markClaimStarted!: () => void;
    const claimStarted = new Promise<void>((resolve) => {
      markClaimStarted = resolve;
    });
    const claimGate = new Promise<void>((resolve) => {
      releaseClaim = resolve;
    });
    const db = {
      markInterrupted: async () => {},
      claimNextQueuedJob: async () => {
        markClaimStarted();
        await claimGate;
        return undefined;
      },
    } as unknown as Database;
    const queue = new JobQueue({ ...config(), concurrency: 1 }, db);
    await queue.start();
    await claimStarted;

    let stopped = false;
    const stopping = queue.stop(0).then(() => {
      stopped = true;
    });
    await Promise.resolve();
    expect(stopped).toBe(false);

    releaseClaim();
    await stopping;
    expect(stopped).toBe(true);
  });

  it('terminates and waits for direct metadata probes during shutdown', async () => {
    const marker = path.join(tempDir, 'direct-probe.pid');
    const termMarker = path.join(tempDir, 'direct-probe.term');
    const stubbornProbe = path.join(tempDir, 'stubborn-direct-probe.mjs');
    await writeFile(
      stubbornProbe,
      `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, String(process.pid));\nprocess.on('SIGTERM', () => writeFileSync(${JSON.stringify(termMarker)}, 'term'));\nsetInterval(() => {}, 1000);\n`,
    );
    await chmod(stubbornProbe, 0o755);

    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    const queue = new JobQueue({ ...config(), ytDlpPath: stubbornProbe }, db);
    await queue.start();
    const probeResult = queue.probe(request.url).then(
      () => undefined,
      (error: unknown) => error,
    );
    await waitForFile(marker);

    await expect(queue.stop(75)).resolves.toBeUndefined();

    expect(await probeResult).toBeInstanceOf(Error);
    await expect(readFile(termMarker, 'utf8')).resolves.toBe('term');
    const childPid = Number(await readFile(marker, 'utf8'));
    expect(() => process.kill(childPid, 0)).toThrow();
    db.close();
  });

  it('revalidates restored queued jobs before starting yt-dlp', async () => {
    const marker = path.join(tempDir, 'unsafe-probe-started');
    const probe = path.join(tempDir, 'marker-probe.mjs');
    await writeFile(
      probe,
      `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, 'started');\n`,
    );
    await chmod(probe, 0o755);

    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    await db.createJob({
      id: 'unsafe-restored-job',
      createdBy: user.username,
      request: { ...request, url: 'https://www.youtube.com/redirect?q=http://127.0.0.1/admin' },
    });
    const queue = new JobQueue({ ...config(), concurrency: 1, ytDlpPath: probe }, db);
    await queue.start();

    const failed = await waitForJobStatus(db, 'unsafe-restored-job', 'failed');
    expect(failed.error).toMatch(/video, playlist, or channel/);
    await expect(readFile(marker)).rejects.toThrow();

    await queue.stop(0);
    db.close();
  });

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
    await queue.resolveAlert(id, 'download-again', user);

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
      ytDlpVersion: 'packaged',
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

  it('always uses the Nix-packaged yt-dlp', () => {
    const appConfig = config();
    expect(ytDlpPathFor(appConfig, { ...request, ytDlpVersion: 'packaged' })).toBe('yt-dlp');
  });

  it('rejects local, private, credential-bearing, and oversized URLs', () => {
    expect(() => validateDownloadUrl('http://127.0.0.1/admin')).toThrow(/local or private/);
    expect(() => validateDownloadUrl('http://[::1]/admin')).toThrow(/local or private/);
    expect(() => validateDownloadUrl('http://[::ffff:127.0.0.1]/admin')).toThrow(/local or private/);
    expect(() => validateDownloadUrl('https://user:password@example.com/video')).toThrow(/credentials/);
    expect(() => validateDownloadUrl(`https://example.com/${'a'.repeat(2048)}`)).toThrow(/2048/);
    expect(() => validateDownloadUrl('https://www.youtube.com/watch?v=fiwd5hMQsEU')).not.toThrow();
  });

  it('allows only exact YouTube hostnames and subdomains, preventing attacker-controlled DNS targets', () => {
    expect(() => validateDownloadUrl('https://youtu.be/fiwd5hMQsEU')).not.toThrow();
    expect(() => validateDownloadUrl('https://music.youtube.com/watch?v=fiwd5hMQsEU')).not.toThrow();
    expect(() => validateDownloadUrl('https://www.youtube-nocookie.com/embed/fiwd5hMQsEU')).not.toThrow();
    expect(() => validateDownloadUrl('https://example.com/video')).toThrow(/only YouTube/);
    expect(() => validateDownloadUrl('https://youtube.com.attacker.example/video')).toThrow(/only YouTube/);
    expect(() => validateDownloadUrl('https://notyoutube.com/video')).toThrow(/only YouTube/);
  });

  it('rejects YouTube redirect and arbitrary paths before yt-dlp can follow them', () => {
    expect(() => validateDownloadUrl('https://www.youtube.com/redirect?q=http://127.0.0.1/admin')).toThrow(/video, playlist, or channel/);
    expect(() => validateDownloadUrl('https://www.youtube.com/results?search_query=example')).toThrow(/video, playlist, or channel/);
    expect(() => validateDownloadUrl('https://www.youtube.com/watch?v=invalid')).toThrow(/video, playlist, or channel/);
    expect(() => validateDownloadUrl('http://www.youtube.com/watch?v=fiwd5hMQsEU')).toThrow(/HTTPS/);
    expect(() => validateDownloadUrl('https://www.youtube.com:8443/watch?v=fiwd5hMQsEU')).toThrow(/default port/);
    expect(() => validateDownloadUrl('https://www.youtube.com/playlist?list=PL123')).not.toThrow();
    expect(() => validateDownloadUrl('https://www.youtube.com/shorts/fiwd5hMQsEU')).not.toThrow();
    expect(() => validateDownloadUrl('https://www.youtube.com/@example/videos')).not.toThrow();
    expect(() => validateDownloadUrl('https://www.youtube.com/channel/UC1234567890')).not.toThrow();
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

const waitForFile = async (file: string): Promise<void> => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await readFile(file);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  throw new Error(`timed out waiting for ${file}`);
};

const waitForJobStatus = async (db: Database, id: string, status: string) => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const job = await db.getJob(id);
    if (job?.status === status) {
      return job;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${id} to become ${status}`);
};
