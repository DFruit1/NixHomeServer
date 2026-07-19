import { spawn, type ChildProcess } from 'node:child_process';
import { cp, mkdir, readdir, rm } from 'node:fs/promises';
import { isIP } from 'node:net';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { AppConfig } from './config.js';
import { Database } from './db.js';
import { runCommand } from './child.js';
import { assertInside, allocateUniqueFolder, folderNameFor, mediaRootFor, prepareDirectory, sanitizeSegment } from './paths.js';
import { buildDownloadArgs, parseProgress, probeUrl } from './ytdlp.js';
import { normalizeDownloadUrl } from '../shared/url.js';
import type { AudioFormat, Chapter, CreateJobRequest, CurrentUser, Job, JobAlert, ProbeResponse } from '../shared/types.js';

const MEDIA_EXTENSIONS = new Set([
  '.aac',
  '.avi',
  '.flac',
  '.m4a',
  '.m4v',
  '.mkv',
  '.mov',
  '.mp3',
  '.mp4',
  '.oga',
  '.ogg',
  '.opus',
  '.wav',
  '.webm',
]);
const THUMBNAIL_EXTENSIONS = new Set(['.jpg', '.jpeg']);
const ALLOWED_DOWNLOAD_HOSTS = ['youtube.com', 'youtu.be', 'youtube-nocookie.com'];
const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const YOUTUBE_PLAYLIST_ID = /^[A-Za-z0-9_-]{2,128}$/;
const YOUTUBE_CHANNEL_SEGMENT = /^[A-Za-z0-9_.@-]{1,128}$/;
const YOUTUBE_CHANNEL_TABS = new Set(['featured', 'playlists', 'shorts', 'streams', 'videos']);

export class JobQueue {
  private readonly running = new Map<string, ChildProcess>();
  private readonly probing = new Map<string, ChildProcess>();
  private readonly externalProbing = new Set<ChildProcess>();
  private readonly externalProbeOperations = new Set<Promise<ProbeResponse>>();
  private readonly postprocessing = new Set<ChildProcess>();
  private active = 0;
  private pumping = false;
  private pumpRequested = false;
  private stopped = false;
  private stopPromise?: Promise<void>;
  private pumpPromise?: Promise<void>;
  private shutdownGraceMs = 5000;
  private readonly workers = new Set<Promise<unknown>>();

  constructor(
    private readonly config: AppConfig,
    private readonly db: Database,
  ) {}

  async start(): Promise<void> {
    if (this.stopped) {
      throw new Error('download queue is shutting down');
    }
    await mkdir(this.config.tempRoot, { recursive: true, mode: 0o750 });
    await this.db.markInterrupted();
    this.pump();
  }

  async stop(graceMs = 5000): Promise<void> {
    if (this.stopPromise) {
      return this.stopPromise;
    }
    this.stopped = true;
    this.pumpRequested = false;
    this.shutdownGraceMs = Math.max(0, graceMs);
    this.stopPromise = this.stopChildrenAndWorkers(this.shutdownGraceMs);
    return this.stopPromise;
  }

  async probe(url: string): Promise<ProbeResponse> {
    if (this.stopped) {
      throw new Error('download queue is shutting down');
    }
    validateDownloadUrl(url);
    let child: ChildProcess | undefined;
    const operation = probeUrl(this.config, url, (spawnedChild) => {
      child = spawnedChild;
      this.externalProbing.add(spawnedChild);
      this.terminateLateChild(spawnedChild);
    });
    this.externalProbeOperations.add(operation);
    try {
      return await operation;
    } finally {
      if (child) {
        this.externalProbing.delete(child);
      }
      this.externalProbeOperations.delete(operation);
    }
  }

  async enqueue(user: CurrentUser, request: CreateJobRequest): Promise<string> {
    if (this.stopped) {
      throw new Error('download queue is shutting down');
    }
    const normalizedRequest = normalizeCreateJobRequest({
      ...request,
      url: normalizeDownloadUrl(request.url),
    });
    validateRequest(normalizedRequest);
    if (normalizedRequest.destination === 'shared' && !user.canWriteShared) {
      throw new Error('shared downloads require shared file access');
    }
    const id = randomUUID();
    const duplicate = normalizedRequest.duplicateConfirmed
      ? undefined
      : await this.db.findCompletedDownload(normalizedRequest, user.username);
    if (duplicate) {
      await this.db.createJob({
        id,
        createdBy: user.username,
        request: normalizedRequest,
        initialStatus: 'alert',
        alert: duplicateAlert(normalizedRequest, duplicate.id),
      });
      return id;
    }
    await this.db.createJob({ id, createdBy: user.username, request: normalizedRequest });
    this.pump();
    return id;
  }

  async retry(id: string, user: CurrentUser): Promise<string> {
    const job = await this.db.getJobForUser(id, user.username);
    if (!job) {
      throw new Error('job not found');
    }
    return this.enqueue(user, job.request);
  }

  async cancel(id: string, user: CurrentUser): Promise<void> {
    const job = await this.db.getJobForUser(id, user.username);
    if (!job) {
      throw new Error('job not found');
    }
    const child = this.running.get(id);
    if (child) {
      killChildGroup(child, 'SIGTERM');
      setTimeout(() => {
        killChildGroup(child, 'SIGKILL');
      }, 5000).unref();
    }
    const probingChild = this.probing.get(id);
    if (probingChild) {
      killChildGroup(probingChild, 'SIGTERM');
      setTimeout(() => {
        killChildGroup(probingChild, 'SIGKILL');
      }, 5000).unref();
    }
    if (job?.status === 'queued' || job?.status === 'alert' || job?.status === 'probing') {
      await this.db.setStatus(id, 'cancelled', 'cancelled before starting');
    }
  }

  async resolveAlert(
    id: string,
    action: 'download-again' | 'split-chapters' | 'single-file' | 'cancel',
    user: CurrentUser,
  ): Promise<void> {
    const job = await this.db.getJobForUser(id, user.username);
    if (!job) {
      throw new Error('job not found');
    }
    if (job.status !== 'alert' || !job.alert) {
      throw new Error('job is not waiting for confirmation');
    }
    if (action === 'cancel') {
      await this.db.setStatus(id, 'cancelled', 'cancelled before starting');
      return;
    }

    if (job.alert.kind === 'duplicate') {
      if (action !== 'download-again') {
        throw new Error('invalid duplicate confirmation action');
      }
      await this.db.clearAlertAndQueue(id, { ...job.request, duplicateConfirmed: true });
      this.pump();
      return;
    }

    if (job.alert.kind === 'chapters') {
      if (action === 'split-chapters') {
        await this.db.clearAlertAndQueue(id, { ...job.request, splitChapters: true, chaptersConfirmed: true });
        this.pump();
        return;
      }
      if (action === 'single-file') {
        await this.db.clearAlertAndQueue(id, { ...job.request, splitChapters: false, chaptersConfirmed: true });
        this.pump();
        return;
      }
      throw new Error('invalid chapter confirmation action');
    }

    if (job.alert.kind === 'folder-collision') {
      if (action !== 'download-again') {
        throw new Error('invalid folder collision confirmation action');
      }
      await this.db.clearAlertAndQueue(id, { ...job.request, outputFolderCollisionConfirmed: true });
      this.pump();
      return;
    }

    throw new Error('unknown alert kind');
  }

  private pump(): void {
    if (this.stopped) {
      return;
    }
    if (this.pumping) {
      this.pumpRequested = true;
      return;
    }
    this.pumping = true;
    let operation!: Promise<void>;
    operation = this.pumpAsync()
      .catch((error) => {
        console.error('queue pump failed', error);
      })
      .finally(() => {
        if (this.pumpPromise === operation) {
          this.pumpPromise = undefined;
        }
        this.pumping = false;
        if (this.pumpRequested && !this.stopped) {
          this.pumpRequested = false;
          this.pump();
        }
      });
    this.pumpPromise = operation;
    void operation;
  }

  private async pumpAsync(): Promise<void> {
    while (!this.stopped && this.active < this.config.concurrency) {
      const job = await this.db.claimNextQueuedJob();
      if (!job) {
        return;
      }
      if (this.stopped) {
        await this.db.setStatus(job.id, 'queued', 'service stopped before the job started');
        return;
      }
      this.active += 1;
      const worker = this.runJob(job)
        .catch(async (error) => {
          if (this.stopped) {
            await rm(path.join(this.config.tempRoot, job.id), { recursive: true, force: true }).catch((cleanupError) => {
              console.error(`failed to clean up interrupted job ${job.id}`, cleanupError);
            });
            await this.db.setStatus(job.id, 'failed', 'interrupted by service shutdown');
            return;
          }
          await this.db.setStatus(job.id, 'failed', error instanceof Error ? error.message : String(error));
        })
        .finally(() => {
          this.active -= 1;
          this.running.delete(job.id);
          this.pump();
        });
      this.workers.add(worker);
      void worker.then(
        () => this.workers.delete(worker),
        () => this.workers.delete(worker),
      );
    }
  }

  private async runJob(job: Job): Promise<void> {
    let request = normalizeCreateJobRequest({
      ...job.request,
      url: normalizeDownloadUrl(job.request.url),
    });
    validateRequest(request);
    if (JSON.stringify(request) !== JSON.stringify(job.request)) {
      await this.db.updateRequest(job.id, request);
    }
    const ytDlpPath = ytDlpPathFor(this.config, request);
    const tempDir = path.join(this.config.tempRoot, job.id);
    await rm(tempDir, { recursive: true, force: true });
    await mkdir(tempDir, { recursive: true, mode: 0o750 });
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }

    let source: ProbeResponse;
    try {
      source = await probeUrl(this.config, request.url, (child) => {
        this.probing.set(job.id, child);
        this.terminateLateChild(child);
      }, ytDlpPath);
    } catch (error) {
      if (await this.abortIfCancelled(job.id, tempDir)) {
        return;
      }
      throw error;
    } finally {
      this.probing.delete(job.id);
    }
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }
    await this.db.setSource(job.id, source);
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }
    if (!request.duplicateConfirmed) {
      const duplicate = await this.db.findCompletedDownload(request, job.createdBy, job.id);
      if (duplicate) {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setAlert(job.id, duplicateAlert(request, duplicate.id));
        return;
      }
    }
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }
    const chapterGate = chapterGateFor(request, source);
    if (chapterGate === 'single-file') {
      request = { ...request, splitChapters: false };
      await this.db.updateRequest(job.id, request);
      await this.db.addEvent(job.id, 'chapters', 'chapter splitting was requested, but this item has no chapters; downloading as a single file');
    }
    if (chapterGate === 'alert') {
      await rm(tempDir, { recursive: true, force: true });
      await this.db.setAlert(job.id, chaptersAlert());
      return;
    }
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }

    const syntheticUser = { username: job.createdBy, canWriteShared: true } as CurrentUser;
    const outputRoot = mediaRootFor(this.config, syntheticUser, request);
    const safeRoot = assertInside(outputRoot, request.destination === 'shared' ? outputRoot : this.config.usersRoot);
    await prepareDirectory(safeRoot);
    const folders = folderNameFor(source, request);
    const outputCandidate = await allocateUniqueFolder(safeRoot, folders);
    const baseFolder = path.join(safeRoot, ...folders);
    if (outputCandidate.collides && !request.outputFolderCollisionConfirmed) {
      await rm(tempDir, { recursive: true, force: true });
      await this.db.setAlert(job.id, folderCollisionAlert(baseFolder, outputCandidate.folder));
      return;
    }
    const outputFolder = outputCandidate.folder;
    assertInside(outputFolder, safeRoot);
    await this.db.setOutput(job.id, safeRoot, outputFolder);

    const title = sanitizeSegment(source.title, 'Unknown Title');
    const id = sanitizeSegment(source.id, 'NOID');
    const baseTemplate = path.join(tempDir, `${title} [${id}].%(ext)s`);
    const chapterTemplate = path.join(tempDir, 'chapters', '%(section_number)02d - %(section_title|Chapter)S.%(ext)s');
    const args = buildDownloadArgs(request, baseTemplate, chapterTemplate);
    await this.db.setStatus(job.id, 'running');
    try {
      await this.runYtDlp(job.id, ytDlpPath, args);
    } catch (error) {
      if (this.stopped) {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setStatus(job.id, 'failed', 'interrupted by service shutdown');
        return;
      }
      if (error instanceof Error && error.message === 'cancelled by user') {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setStatus(job.id, 'cancelled', 'cancelled by user');
        return;
      }
      throw error;
    }
    if (await this.abortIfCancelled(job.id, tempDir)) {
      return;
    }

    await this.db.setStatus(job.id, 'postprocessing');
    if (request.splitChapters && request.mediaType === 'audio') {
      await this.db.setProgress(job.id, { phase: 'postprocess' });
      await splitAudioChapters(
        tempDir,
        source,
        request.audioFormat ?? 'flac',
        request.embedAudioCoverArt !== false,
        {
          isStopped: () => this.stopped,
          onSpawn: (child) => {
            this.postprocessing.add(child);
            this.terminateLateChild(child);
          },
          onExit: (child) => this.postprocessing.delete(child),
        },
      );
    }
    await this.db.setProgress(job.id, { phase: 'move' });
    const sourceDir = request.splitChapters ? path.join(tempDir, 'chapters') : tempDir;
    await mkdir(outputFolder, { recursive: true, mode: 0o775 });
    await copyDirectoryContents(sourceDir, outputFolder);
    await this.recordFiles(job.id, outputFolder);
    await rm(tempDir, { recursive: true, force: true });
    await this.db.setProgress(job.id, null);
    await this.db.setStatus(job.id, 'completed');
  }

  private async abortIfCancelled(jobId: string, tempDir: string): Promise<boolean> {
    const job = await this.db.getJob(jobId);
    if (this.stopped) {
      await rm(tempDir, { recursive: true, force: true });
      if (job && !['completed', 'failed', 'cancelled'].includes(job.status)) {
        await this.db.setStatus(jobId, 'failed', 'interrupted by service shutdown');
      }
      return true;
    }
    if (job?.status === 'cancelled') {
      await rm(tempDir, { recursive: true, force: true });
      return true;
    }
    return false;
  }

  private async runYtDlp(jobId: string, ytDlpPath: string, args: string[]): Promise<void> {
    if (this.stopped) {
      throw new Error('download queue is shutting down');
    }
    await new Promise<void>((resolve, reject) => {
      const child = spawn(ytDlpPath, args, {
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      this.running.set(jobId, child);
      this.terminateLateChild(child);
      let stderr = '';
      const onLine = (line: string) => {
        const parsed = parseProgress(line);
        if (parsed) {
          void this.db.setProgress(jobId, { phase: 'download', ...parsed });
        }
      };
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => String(chunk).split(/\r?\n/).forEach(onLine));
      child.stderr.on('data', (chunk) => {
        stderr += String(chunk);
        String(chunk).split(/\r?\n/).forEach(onLine);
      });
      child.on('error', reject);
      child.on('close', (code, signal) => {
        this.running.delete(jobId);
        if (signal === 'SIGTERM' || signal === 'SIGKILL') {
          reject(new Error('cancelled by user'));
        } else if (code === 0) {
          resolve();
        } else {
          reject(new Error(stderr.trim() || `yt-dlp exited with code ${code ?? 'unknown'}`));
        }
      });
    });
  }

  private async recordFiles(jobId: string, folder: string): Promise<void> {
    const entries = await collectFiles(folder);
    for (const entry of entries) {
      const fullPath = entry;
      const relative = path.relative(folder, fullPath);
      const extension = path.extname(entry).toLowerCase();
      const kind = MEDIA_EXTENSIONS.has(extension) ? 'media' : extension === '.jpg' || extension === '.jpeg' ? 'cover' : 'metadata';
      await this.db.addFile(jobId, relative, kind);
    }
  }

  private async stopChildrenAndWorkers(graceMs: number): Promise<void> {
    const pumpAtShutdown = this.pumpPromise;
    const children = [...new Set([
      ...this.running.values(),
      ...this.probing.values(),
      ...this.externalProbing,
      ...this.postprocessing,
    ])];
    const exits = children.map((child) => waitForChildExit(child));
    for (const child of children) {
      killChildGroup(child, 'SIGTERM');
    }
    if (children.length > 0) {
      const exitedDuringGrace = await Promise.race([
        Promise.all(exits).then(() => true),
        delay(graceMs).then(() => false),
      ]);
      if (!exitedDuringGrace) {
        for (const child of children) {
          if (!childHasExited(child)) {
            killChildGroup(child, 'SIGKILL');
          }
        }
      }
      await Promise.all(exits);
    }
    await pumpAtShutdown;
    await Promise.allSettled([...this.workers, ...this.externalProbeOperations]);
  }

  private terminateLateChild(child: ChildProcess): void {
    if (!this.stopped || childHasExited(child)) {
      return;
    }
    killChildGroup(child, 'SIGTERM');
    const cleanup = () => {
      clearTimeout(killTimer);
      child.off('close', cleanup);
      child.off('error', cleanup);
    };
    const killTimer = setTimeout(() => {
      cleanup();
      if (!childHasExited(child)) {
        killChildGroup(child, 'SIGKILL');
      }
    }, this.shutdownGraceMs);
    killTimer.unref();
    child.once('close', cleanup);
    child.once('error', cleanup);
  }
}

export const validateRequest = (request: CreateJobRequest): void => {
  validateDownloadUrl(request.url);
  if (request.destination !== 'personal' && request.destination !== 'shared') {
    throw new Error('destination must be personal or shared');
  }
  if (typeof request.splitChapters !== 'boolean') {
    throw new Error('split chapters flag must be a boolean');
  }
  if (request.ytDlpVersion !== 'packaged') {
    throw new Error('yt-dlp version must be the reproducible packaged build');
  }
  if (request.mediaType === 'audio') {
    if (!request.audioFormat || !['flac', 'm4a', 'mp3', 'opus', 'wav'].includes(request.audioFormat)) {
      throw new Error('unsupported audio format');
    }
    if (request.audioQuality && !['best', 'high', 'medium', 'low'].includes(request.audioQuality)) {
      throw new Error('unsupported audio quality');
    }
    if (request.saveAudioToAudiobooks != null && typeof request.saveAudioToAudiobooks !== 'boolean') {
      throw new Error('audiobook destination flag must be a boolean');
    }
    if (request.embedAudioCoverArt != null && typeof request.embedAudioCoverArt !== 'boolean') {
      throw new Error('audio cover art flag must be a boolean');
    }
  } else if (request.mediaType === 'video') {
    if (!request.videoContainer || !['mkv', 'mp4', 'webm'].includes(request.videoContainer)) {
      throw new Error('unsupported video container');
    }
    if (!request.videoQuality || !['best', '2160p', '1440p', '1080p', '720p', '480p'].includes(request.videoQuality)) {
      throw new Error('unsupported video quality');
    }
  } else {
    throw new Error('media type must be audio or video');
  }
};

export const validateDownloadUrl = (rawUrl: string): void => {
  if (typeof rawUrl !== 'string' || rawUrl.length > 2048) {
    throw new Error('download URL must be at most 2048 characters');
  }
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error('download URL is invalid');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('download URL must use http or https');
  }
  if (parsed.username || parsed.password) {
    throw new Error('download URL must not contain credentials');
  }
  const hostname = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (hostname === 'localhost' || hostname.endsWith('.localhost') || isPrivateAddress(hostname)) {
    throw new Error('download URL must not target a local or private address');
  }
  if (!ALLOWED_DOWNLOAD_HOSTS.some((allowed) => hostname === allowed || hostname.endsWith(`.${allowed}`))) {
    throw new Error('download URL host is not supported; only YouTube URLs are allowed');
  }
  if (parsed.protocol !== 'https:' || parsed.port) {
    throw new Error('YouTube download URLs must use HTTPS on the default port');
  }
  if (!isSupportedYouTubePath(parsed, hostname)) {
    throw new Error('download URL must identify a supported YouTube video, playlist, or channel');
  }
};

const isSupportedYouTubePath = (url: URL, hostname: string): boolean => {
  const segments = url.pathname.split('/').filter(Boolean);
  if (hostname === 'youtu.be' || hostname.endsWith('.youtu.be')) {
    return segments.length === 1 && YOUTUBE_VIDEO_ID.test(segments[0]);
  }
  if (hostname === 'youtube-nocookie.com' || hostname.endsWith('.youtube-nocookie.com')) {
    return segments.length === 2 && segments[0] === 'embed' && YOUTUBE_VIDEO_ID.test(segments[1]);
  }
  if (url.pathname === '/watch') {
    const videoId = url.searchParams.get('v');
    const playlistId = url.searchParams.get('list');
    return (videoId != null && YOUTUBE_VIDEO_ID.test(videoId))
      || (videoId == null && playlistId != null && YOUTUBE_PLAYLIST_ID.test(playlistId));
  }
  if (url.pathname === '/playlist') {
    const playlistId = url.searchParams.get('list');
    return playlistId != null && YOUTUBE_PLAYLIST_ID.test(playlistId);
  }
  if (segments[0]?.startsWith('@')) {
    return YOUTUBE_CHANNEL_SEGMENT.test(segments[0])
      && (segments.length === 1 || (segments.length === 2 && YOUTUBE_CHANNEL_TABS.has(segments[1])));
  }
  if (['c', 'channel', 'user'].includes(segments[0])) {
    return segments.length >= 2
      && segments.length <= 3
      && YOUTUBE_CHANNEL_SEGMENT.test(segments[1])
      && (segments.length === 2 || YOUTUBE_CHANNEL_TABS.has(segments[2]));
  }
  return segments.length === 2
    && ['embed', 'live', 'shorts', 'v'].includes(segments[0])
    && YOUTUBE_VIDEO_ID.test(segments[1]);
};

export const normalizeCreateJobRequest = (request: CreateJobRequest): CreateJobRequest => ({
  ...request,
  ytDlpVersion: 'packaged',
  splitChapters: request.splitChapters ?? true,
  embedAudioCoverArt: request.mediaType === 'audio' ? (request.embedAudioCoverArt ?? true) : undefined,
});

export const ytDlpPathFor = (config: AppConfig, _request: CreateJobRequest): string => config.ytDlpPath;

const isPrivateAddress = (hostname: string): boolean => {
  const mappedAddress = ipv4FromMappedIpv6(hostname);
  if (mappedAddress) {
    return isPrivateAddress(mappedAddress);
  }
  const family = isIP(hostname);
  if (family === 4) {
    const [a, b] = hostname.split('.').map(Number);
    return a === 0
      || a === 10
      || a === 127
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127)
      || a >= 224;
  }
  if (family === 6) {
    return hostname === '::1'
      || hostname === '::'
      || hostname.startsWith('fc')
      || hostname.startsWith('fd')
      || /^fe[89ab]/.test(hostname)
      || hostname.startsWith('ff');
  }
  return false;
};

const ipv4FromMappedIpv6 = (hostname: string): string | undefined => {
  const match = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i.exec(hostname);
  if (!match) {
    return undefined;
  }
  const high = Number.parseInt(match[1], 16);
  const low = Number.parseInt(match[2], 16);
  return `${high >>> 8}.${high & 0xff}.${low >>> 8}.${low & 0xff}`;
};

export const chapterGateFor = (request: CreateJobRequest, source: ProbeResponse): 'download' | 'single-file' | 'alert' => {
  if (request.splitChapters && source.chapters.length === 0) {
    return 'single-file';
  }
  if (!request.splitChapters && source.chapters.length > 0 && !request.chaptersConfirmed) {
    return 'alert';
  }
  return 'download';
};

const duplicateAlert = (request: CreateJobRequest, duplicateJobId: string): JobAlert => ({
  kind: 'duplicate',
  message: `This ${request.mediaType} has been downloaded before. Do you want to download again?`,
  duplicateJobId,
});

const chaptersAlert = (): JobAlert => ({
  kind: 'chapters',
  message: 'This item has chapters. Would you like to download it with chapters split?',
});

const folderCollisionAlert = (folder: string, alternativeFolder: string): JobAlert => ({
  kind: 'folder-collision',
  message: `Files for this download already exist at ${folder}. Download another copy to ${alternativeFolder}?`,
});

const killChildGroup = (child: ChildProcess, signal: NodeJS.Signals): void => {
  try {
    if (child.pid) {
      process.kill(-child.pid, signal);
      return;
    }
  } catch (error) {
    const code = typeof error === 'object' && error != null && 'code' in error ? String(error.code) : '';
    if (code !== 'ESRCH') {
      throw error;
    }
  }
  try {
    child.kill(signal);
  } catch (error) {
    const code = typeof error === 'object' && error != null && 'code' in error ? String(error.code) : '';
    if (code !== 'ESRCH') {
      throw error;
    }
  }
};

const childHasExited = (child: ChildProcess): boolean => child.exitCode !== null || child.signalCode !== null;

const waitForChildExit = (child: ChildProcess): Promise<void> => {
  if (childHasExited(child)) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const done = () => {
      child.off('close', done);
      child.off('error', done);
      resolve();
    };
    child.once('close', done);
    child.once('error', done);
  });
};

const delay = (milliseconds: number): Promise<void> => new Promise((resolve) => {
  const timer = setTimeout(resolve, milliseconds);
  timer.unref();
});

const copyDirectoryContents = async (sourceDir: string, destinationDir: string): Promise<void> => {
  const entries = await readdir(sourceDir, { withFileTypes: true });
  for (const entry of entries) {
    await cp(path.join(sourceDir, entry.name), path.join(destinationDir, entry.name), {
      recursive: true,
      force: false,
      errorOnExist: true,
    });
  }
};

type AudioChapterSpec = {
  chapter: Chapter;
  start: number;
  duration: number;
};

const splitAudioChapters = async (
  tempDir: string,
  source: ProbeResponse,
  audioFormat: AudioFormat,
  embedCoverArt: boolean,
  childHooks?: {
    isStopped: () => boolean;
    onSpawn: (child: ChildProcess) => void;
    onExit: (child: ChildProcess) => void;
  },
): Promise<void> => {
  const input = await findDownloadedMedia(tempDir);
  const chapterDir = path.join(tempDir, 'chapters');
  await rm(chapterDir, { recursive: true, force: true });
  await mkdir(chapterDir, { recursive: true, mode: 0o750 });
  const coverPath = embedCoverArt ? await copyFirstThumbnail(tempDir, chapterDir) : undefined;

  const specs = audioChapterSpecs(source);
  for (const spec of specs) {
    if (childHooks?.isStopped()) {
      throw new Error('interrupted by service shutdown');
    }
    const title = sanitizeSegment(spec.chapter.title, 'Chapter');
    const output = path.join(chapterDir, `${String(spec.chapter.index).padStart(2, '0')} - ${title}.${audioFormat}`);
    const args = buildAudioChapterFfmpegArgs({
      input,
      output,
      chapter: spec.chapter,
      start: spec.start,
      duration: spec.duration,
      audioFormat,
      coverPath,
    });
    const timeoutMs = Math.max(120000, Math.ceil(spec.duration + 60) * 1000);
    let result = await runTrackedCommand('ffmpeg', args, timeoutMs, childHooks);
    if (result.code !== 0 && coverPath) {
      if (childHooks?.isStopped()) {
        throw new Error('interrupted by service shutdown');
      }
      result = await runTrackedCommand(
        'ffmpeg',
        buildAudioChapterFfmpegArgs({
          input,
          output,
          chapter: spec.chapter,
          start: spec.start,
          duration: spec.duration,
          audioFormat,
        }),
        timeoutMs,
        childHooks,
      );
    }
    if (result.code !== 0) {
      throw new Error(result.stderr.trim() || `ffmpeg exited with code ${result.code ?? 'unknown'} while splitting chapter ${spec.chapter.index}`);
    }
  }
};

const runTrackedCommand = async (
  command: string,
  args: string[],
  timeoutMs: number,
  childHooks?: {
    onSpawn: (child: ChildProcess) => void;
    onExit: (child: ChildProcess) => void;
  },
) => {
  let spawnedChild: ChildProcess | undefined;
  try {
    return await runCommand(command, args, {
      timeoutMs,
      onSpawn: (child) => {
        spawnedChild = child;
        childHooks?.onSpawn(child);
      },
    });
  } finally {
    if (spawnedChild) {
      childHooks?.onExit(spawnedChild);
    }
  }
};

type AudioChapterFfmpegArgs = {
  input: string;
  output: string;
  chapter: Chapter;
  start: number;
  duration: number;
  audioFormat: AudioFormat;
  coverPath?: string;
};

export const buildAudioChapterFfmpegArgs = ({
  input,
  output,
  chapter,
  start,
  duration,
  audioFormat,
  coverPath,
}: AudioChapterFfmpegArgs): string[] => {
  const embedCover = coverPath != null && audioFormatSupportsEmbeddedCover(audioFormat);
  return [
    '-hide_banner',
    '-nostdin',
    '-y',
    '-ss',
    formatSeconds(start),
    '-t',
    formatSeconds(duration),
    '-i',
    input,
    ...(embedCover ? ['-i', coverPath] : []),
    '-map',
    '0:a:0',
    ...(embedCover ? ['-map', '1:v:0'] : []),
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    ...audioEncoderArgs(audioFormat),
    ...(embedCover ? ['-c:v', 'mjpeg', '-disposition:v', 'attached_pic'] : ['-vn']),
    '-metadata',
    `title=${chapter.title}`,
    '-metadata',
    `track=${chapter.index}`,
    output,
  ];
};

const audioFormatSupportsEmbeddedCover = (audioFormat: AudioFormat): boolean => ['flac', 'm4a', 'mp3'].includes(audioFormat);

const audioEncoderArgs = (audioFormat: AudioFormat): string[] => {
  switch (audioFormat) {
    case 'flac':
      return ['-c:a', 'flac'];
    case 'wav':
      return ['-c:a', 'pcm_s16le'];
    case 'm4a':
      return ['-c:a', 'aac', '-b:a', '192k'];
    case 'mp3':
      return ['-c:a', 'libmp3lame', '-q:a', '2'];
    case 'opus':
      return ['-c:a', 'libopus', '-b:a', '128k'];
  }
};

const findDownloadedMedia = async (tempDir: string): Promise<string> => {
  const entries = await collectFiles(tempDir);
  const mediaFiles = entries.filter((entry) => MEDIA_EXTENSIONS.has(path.extname(entry).toLowerCase()));
  if (mediaFiles.length === 0) {
    throw new Error('yt-dlp did not produce a source media file for audio chapter splitting');
  }
  if (mediaFiles.length > 1) {
    throw new Error(`expected one source media file for audio chapter splitting, found ${mediaFiles.length}`);
  }
  return mediaFiles[0];
};

const copyFirstThumbnail = async (tempDir: string, chapterDir: string): Promise<string | undefined> => {
  const entries = await collectFiles(tempDir);
  const thumbnail = entries.find((entry) => THUMBNAIL_EXTENSIONS.has(path.extname(entry).toLowerCase()));
  if (!thumbnail) {
    return undefined;
  }
  const coverPath = path.join(chapterDir, 'cover.jpg');
  await cp(thumbnail, coverPath, {
    force: false,
    errorOnExist: true,
  });
  return coverPath;
};

export const audioChapterSpecs = (source: ProbeResponse): AudioChapterSpec[] =>
  source.chapters.map((chapter, index) => {
    const nextChapter = source.chapters[index + 1];
    const end = chapter.endTime ?? nextChapter?.startTime ?? source.durationSeconds;
    if (end == null) {
      throw new Error(`chapter ${chapter.index} is missing an end time and the source duration is unknown`);
    }
    const duration = end - chapter.startTime;
    if (!Number.isFinite(chapter.startTime) || !Number.isFinite(duration) || duration <= 0) {
      throw new Error(`chapter ${chapter.index} has an invalid start or end time`);
    }
    return {
      chapter,
      start: chapter.startTime,
      duration,
    };
  });

const formatSeconds = (seconds: number): string => seconds.toFixed(3);

const collectFiles = async (directory: string): Promise<string[]> => {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await collectFiles(fullPath)));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
};
