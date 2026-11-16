import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import {
  JobQueue,
  chapterGateFor,
  normalizeCreateJobRequest,
  validateDownloadUrl,
  validateRequest,
  ytDlpPathFor,
} from '../queue.js';
import type { CreateJobRequest, CurrentUser, ProbeResponse } from '../../shared/types.js';

let tempDir = '';

const HAS_FFMPEG = spawnSync('ffmpeg', ['-version']).status === 0 && spawnSync('ffprobe', ['-version']).status === 0;

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
  authGroupsClaim: 'groups',
  appVersion: '0.0.0-test',
  appVersionDate: '',
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
    await db.close();
  });

  it('waits for TERM then KILL child exit before shutdown resolves', async () => {
    const marker = path.join(tempDir, 'child.pid');
    const termMarker = path.join(tempDir, 'child.term');
    const stubbornProbe = path.join(tempDir, 'stubborn-probe.mjs');
    await writeFile(
      stubbornProbe,
      `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nprocess.on('SIGTERM', () => writeFileSync(${JSON.stringify(termMarker)}, 'term'));\nwriteFileSync(${JSON.stringify(marker)}, String(process.pid));\nsetInterval(() => {}, 1000);\n`,
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
    await db.close();
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
      `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nprocess.on('SIGTERM', () => writeFileSync(${JSON.stringify(termMarker)}, 'term'));\nwriteFileSync(${JSON.stringify(marker)}, String(process.pid));\nsetInterval(() => {}, 1000);\n`,
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
    await db.close();
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
    await db.close();
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
    const one = [{ index: 1, title: 'Intro', startTime: 0 }];
    const two = [...one, { index: 2, title: 'Main', startTime: 30 }];
    expect(chapterGateFor({ ...request, splitChapters: false }, { ...source, chapters: two })).toBe('alert');
    expect(chapterGateFor({ ...request, splitChapters: true }, source)).toBe('single-file');
    // One chapter is the whole item: nothing to split and nothing to ask.
    expect(chapterGateFor({ ...request, splitChapters: true }, { ...source, chapters: one })).toBe('single-file');
    expect(chapterGateFor({ ...request, splitChapters: false }, { ...source, chapters: one })).toBe('download');
    expect(
      chapterGateFor({ ...request, splitChapters: false, chaptersConfirmed: true }, { ...source, chapters: two }),
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

  it('defaults the transcript option off and rejects a non-boolean value', () => {
    expect(normalizeCreateJobRequest({ ...request })).toMatchObject({ downloadTranscript: false });
    expect(() =>
      validateRequest({ ...request, ytDlpVersion: 'packaged', downloadTranscript: 'yes' as unknown as boolean }),
    ).toThrow(/transcript flag must be a boolean/);
    expect(() =>
      validateRequest({ ...request, ytDlpVersion: 'packaged', downloadTranscript: true }),
    ).not.toThrow();
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
});

describe('queue output layout', () => {
  const writeFakeYtDlp = async (body: string): Promise<string> => {
    const fake = path.join(tempDir, 'fake-yt-dlp.mjs');
    await writeFile(fake, `#!${process.execPath}\n${body}`);
    await chmod(fake, 0o755);
    return fake;
  };

  const probeJson = JSON.stringify({
    id: 'abc123',
    title: 'Test Song',
    channel: 'Test Channel',
    upload_date: '20260101',
    duration: 120,
    chapters: [],
    _type: 'video',
  });

  it('moves only media and metadata into the library and drops loose thumbnails', async () => {
    const fake = await writeFakeYtDlp(`
import { writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
if (args.includes('--dump-single-json')) {
  process.stdout.write(${JSON.stringify(probeJson)});
  process.exit(0);
}
const template = args[args.indexOf('-o') + 1];
const media = template.replace('%(ext)s', 'flac');
writeFileSync(media, 'audio');
writeFileSync(media.replace(/\\.flac$/, '.jpg'), 'thumb');
writeFileSync(media.replace(/\\.flac$/, '.info.json'), '{}');
process.stdout.write('[download] 100% of 1MiB\\n');
`);

    const db = new Database(path.join(tempDir, 'state.sqlite'));
    await db.migrate();
    const queue = new JobQueue({ ...config(), concurrency: 1, ytDlpPath: fake }, db);
    await queue.start();
    const id = await queue.enqueue(user, request);
    const job = await waitForJobStatus(db, id, 'completed');

    const outputFolder = job.outputFolder ?? '';
    expect(path.basename(outputFolder)).toBe('Test Channel');
    await expect(readdir(outputFolder)).resolves.toEqual(expect.arrayContaining(['Test Song.flac', 'Test Song.info.json']));
    await expect(readdir(outputFolder)).resolves.not.toEqual(expect.arrayContaining([expect.stringMatching(/\.(?:jpe?g|png|webp)$/i)]));
    expect([...job.files].sort()).toEqual(['Test Song.flac', 'Test Song.info.json']);

    await queue.stop(0);
    await db.close();
  });

  describe.runIf(HAS_FFMPEG)('with a real chapter split', () => {
    let fixtures = '';

    beforeAll(async () => {
      fixtures = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-split-fixture-'));
      const ffmpeg = (args: string[]) => {
        const result = spawnSync('ffmpeg', ['-nostdin', '-v', 'error', '-y', ...args]);
        if (result.status !== 0) {
          throw new Error(String(result.stderr));
        }
      };
      ffmpeg(['-f', 'lavfi', '-i', 'sine=f=440:d=4', '-c:a', 'flac', path.join(fixtures, 'source.flac')]);
      ffmpeg(['-f', 'lavfi', '-i', 'color=red:s=64x64', '-frames:v', '1', path.join(fixtures, 'thumb.jpg')]);
    });

    afterAll(async () => {
      await rm(fixtures, { recursive: true, force: true });
    });

    const chapterProbe = JSON.stringify({
      id: 'abc123',
      title: 'Test Song',
      channel: 'Test Channel',
      upload_date: '20260101',
      duration: 4,
      chapters: [
        { title: 'Intro', start_time: 0, end_time: 2 },
        { title: 'Main', start_time: 2, end_time: 4 },
      ],
      _type: 'video',
    });

    // Stands in for yt-dlp: the probe JSON, then a real FLAC download with its
    // thumbnail, info.json and (when asked for) transcripts beside it.
    const fakeDownloader = () =>
      writeFakeYtDlp(`
import { copyFileSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
if (args.includes('--dump-single-json')) {
  process.stdout.write(${JSON.stringify(chapterProbe)});
  process.exit(0);
}
const template = args[args.indexOf('-o') + 1];
const media = template.replace('%(ext)s', 'flac');
copyFileSync(process.env.SPLIT_FIXTURES + '/source.flac', media);
copyFileSync(process.env.SPLIT_FIXTURES + '/thumb.jpg', media.replace(/\\.flac$/, '.jpg'));
writeFileSync(media.replace(/\\.flac$/, '.info.json'), '{}');
if (args.includes('--write-subs')) {
  writeFileSync(media.replace(/\\.flac$/, '.en-orig.srt'), '1\\n00:00:00,000 --> 00:00:01,000\\ntranscript\\n');
  writeFileSync(media.replace(/\\.flac$/, '.en.srt'), '1\\n00:00:00,000 --> 00:00:01,000\\ntranscript\\n');
}
process.stdout.write('[download] 100% of 1MiB\\n');
`);

    const runSplitJob = async (overrides: Partial<CreateJobRequest>) => {
      process.env.SPLIT_FIXTURES = fixtures;
      const fake = await fakeDownloader();
      const db = new Database(path.join(tempDir, 'state.sqlite'));
      await db.migrate();
      const queue = new JobQueue({ ...config(), concurrency: 1, ytDlpPath: fake }, db);
      try {
        await queue.start();
        const id = await queue.enqueue(user, { ...request, splitChapters: true, chaptersConfirmed: true, ...overrides });
        // Real ffmpeg runs four passes over the file.
        return await waitForJobStatus(db, id, 'completed', 30_000);
      } finally {
        await queue.stop(0);
        await db.close();
      }
    };

    it('files verified chapter files with embedded covers and keeps the thumbnail only in the metadata folder', async () => {
      const job = await runSplitJob({});

      // A chapter split gets its own folder inside the channel folder.
      const outputFolder = job.outputFolder ?? '';
      expect(path.relative(path.dirname(path.dirname(outputFolder)), outputFolder)).toBe(path.join('Test Channel', 'Test Song'));
      const names = (await readdir(outputFolder)).sort();
      expect(names).toEqual(['.youtube-downloader', '01 - Intro.flac', '02 - Main.flac', 'Test Song.info.json']);
      expect([...job.files].sort()).toEqual(names.slice(1));
      const cover = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'stream_disposition=attached_pic', '-of', 'csv=p=0', path.join(outputFolder, '01 - Intro.flac')]);
      expect(String(cover.stdout)).toContain('1');

      // The manifest ties each chapter file to its chapter and records the
      // original's streams, so the split can be joined back exactly.
      const metadata = path.join(outputFolder, '.youtube-downloader');
      expect((await readdir(metadata)).sort()).toEqual(['.nomedia', 'abc123.jpg', 'abc123.json', 'abc123.restore']);
      const manifest = JSON.parse(await readFile(path.join(metadata, 'abc123.json'), 'utf8'));
      expect(manifest.chapters).toEqual([
        { index: 1, title: 'Intro', startTime: 0, endTime: 2 },
        { index: 2, title: 'Main', startTime: 2, endTime: 4 },
      ]);
      expect(manifest.files.map(({ path: file, role, chapter }: { path: string; role: string; chapter?: number }) => ({ file, role, chapter }))).toEqual([
        { file: 'Test Song.info.json', role: 'info-json', chapter: undefined },
        { file: '01 - Intro.flac', role: 'chapter', chapter: 1 },
        { file: '02 - Main.flac', role: 'chapter', chapter: 2 },
      ]);
      // The cut falls on the first FLAC frame (4096 samples) at or after 2 s.
      expect(manifest.files[2].start).toBeGreaterThanOrEqual(2);
      expect(manifest.files[2].start).toBeLessThan(2.1);
      expect(manifest.state).toEqual({ split: true, coverEmbedded: true });
      expect(manifest.original).toMatchObject({
        name: 'Test Song.flac',
        extension: '.flac',
        coverEmbedded: true,
        method: 'stream-copy',
        streams: [{ type: 'audio', codec: 'flac' }],
      });
      // The restore file in the metadata folder is the one the manifest names.
      expect(manifest.original.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(manifest.original.restore.sha256).toBe(
        createHash('sha256').update(await readFile(path.join(metadata, 'abc123.restore'))).digest('hex'),
      );
      expect(manifest.files[1].streams[0].bytes + manifest.files[2].streams[0].bytes).toBe(manifest.original.streams[0].bytes);
      expect(manifest.hasThumbnail).toBe(true);
    });

    it('carries transcript sidecars across chapter splitting, which only relocates media', async () => {
      const job = await runSplitJob({ downloadTranscript: true });

      const outputFolder = job.outputFolder ?? '';
      const names = (await readdir(outputFolder)).sort();
      expect(names).toEqual([
        '.youtube-downloader',
        '01 - Intro.flac',
        '02 - Main.flac',
        'Test Song.en-orig.srt',
        'Test Song.en.srt',
        'Test Song.info.json',
      ]);
      expect([...job.files].sort()).toEqual(names.slice(1));
    });
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

const waitForJobStatus = async (db: Database, id: string, status: string, timeoutMs = 1000) => {
  for (let attempt = 0; attempt < timeoutMs / 10; attempt += 1) {
    const job = await db.getJob(id);
    if (job?.status === status) {
      return job;
    }
    if (job?.status === 'failed' && status !== 'failed') {
      throw new Error(`job ${id} failed: ${job.error ?? 'no error recorded'}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${id} to become ${status}`);
};
