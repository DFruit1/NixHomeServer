import { spawn, type ChildProcess } from 'node:child_process';
import { access, cp, mkdir, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { AppConfig } from './config.js';
import { Database } from './db.js';
import { assertInside, allocateUniqueFolder, folderNameFor, mediaRootFor, prepareDirectory, sanitizeSegment } from './paths.js';
import { buildDownloadArgs, parseProgress, probeUrl } from './ytdlp.js';
import { normalizeDownloadUrl } from '../shared/url.js';
import type { CreateJobRequest, CurrentUser, Job, JobAlert, ProbeResponse } from '../shared/types.js';
import { collectFiles, isMediaFile, splitAudioChapters } from './audio-chapters.js';
import {
  chapterGateFor,
  normalizeCreateJobRequest,
  validateDownloadUrl,
  validateRequest,
  ytDlpPathFor,
} from './request-validation.js';

export {
  chapterGateFor,
  normalizeCreateJobRequest,
  validateDownloadUrl,
  validateRequest,
  ytDlpPathFor,
} from './request-validation.js';
export { audioChapterSpecs, buildAudioChapterFfmpegArgs } from './audio-chapters.js';


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
    const baseFolder = path.join(safeRoot, ...folders);
    let outputFolder: string;
    if (request.includeChannel) {
      outputFolder = baseFolder;
    } else {
      const outputCandidate = await allocateUniqueFolder(safeRoot, folders);
      if (outputCandidate.collides && !request.outputFolderCollisionConfirmed) {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setAlert(job.id, folderCollisionAlert(baseFolder, outputCandidate.folder));
        return;
      }
      outputFolder = outputCandidate.folder;
    }
    assertInside(outputFolder, safeRoot);
    await this.db.setOutput(job.id, safeRoot, outputFolder);

    const title = sanitizeSegment(source.title, 'Unknown Title');
    const baseTemplate = path.join(tempDir, `${title}.%(ext)s`);
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
      const kind = isMediaFile(entry) ? 'media' : extension === '.jpg' || extension === '.jpeg' ? 'cover' : 'metadata';
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
    const destination = await allocateUniqueDestination(destinationDir, entry.name);
    await cp(path.join(sourceDir, entry.name), destination, {
      recursive: true,
      force: false,
      errorOnExist: true,
    });
  }
};

const allocateUniqueDestination = async (directory: string, name: string): Promise<string> => {
  const extension = path.extname(name);
  const base = extension ? name.slice(0, -extension.length) : name;
  for (let index = 0; index < 1000; index += 1) {
    const candidate = index === 0 ? name : `${base} (${index})${extension}`;
    try {
      await access(path.join(directory, candidate));
    } catch {
      return path.join(directory, candidate);
    }
  }
  throw new Error(`could not allocate a unique output name for ${name} under ${directory}`);
};
