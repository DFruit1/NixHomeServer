import { spawn, type ChildProcess } from 'node:child_process';
import { cp, mkdir, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { AppConfig } from './config.js';
import { Database } from './db.js';
import { runCommand } from './child.js';
import { assertInside, folderNameFor, mediaRootFor, prepareDirectory, sanitizeSegment, uniqueFolder } from './paths.js';
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

export class JobQueue {
  private readonly running = new Map<string, ChildProcess>();
  private active = 0;

  constructor(
    private readonly config: AppConfig,
    private readonly db: Database,
  ) {}

  async start(): Promise<void> {
    await mkdir(this.config.tempRoot, { recursive: true, mode: 0o750 });
    await this.db.markInterrupted();
    this.pump();
  }

  async enqueue(user: CurrentUser, request: CreateJobRequest): Promise<string> {
    const normalizedRequest = {
      ...request,
      url: normalizeDownloadUrl(request.url),
    };
    validateRequest(normalizedRequest);
    if (normalizedRequest.destination === 'shared' && !user.canWriteShared) {
      throw new Error('shared downloads require shared file access');
    }
    const id = randomUUID();
    const duplicate = normalizedRequest.duplicateConfirmed ? undefined : await this.db.findCompletedDownload(normalizedRequest);
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
    const job = await this.db.getJob(id);
    if (!job) {
      throw new Error('job not found');
    }
    return this.enqueue(user, job.request);
  }

  async cancel(id: string): Promise<void> {
    const child = this.running.get(id);
    if (child) {
      killChildGroup(child, 'SIGTERM');
      setTimeout(() => {
        killChildGroup(child, 'SIGKILL');
      }, 5000).unref();
    }
    const job = await this.db.getJob(id);
    if (job?.status === 'queued' || job?.status === 'alert') {
      await this.db.setStatus(id, 'cancelled', 'cancelled before starting');
    }
  }

  async resolveAlert(id: string, action: 'download-again' | 'split-chapters' | 'single-file' | 'cancel'): Promise<void> {
    const job = await this.db.getJob(id);
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

    throw new Error('unknown alert kind');
  }

  private pump(): void {
    void this.pumpAsync().catch((error) => {
      console.error('queue pump failed', error);
    });
  }

  private async pumpAsync(): Promise<void> {
    while (this.active < this.config.concurrency) {
      const [job] = await this.db.queuedJobs();
      if (!job) {
        return;
      }
      this.active += 1;
      void this.runJob(job)
        .catch((error) => this.db.setStatus(job.id, 'failed', error instanceof Error ? error.message : String(error)))
        .finally(() => {
          this.active -= 1;
          this.running.delete(job.id);
          this.pump();
        });
    }
  }

  private async runJob(job: Job): Promise<void> {
    let request = job.request;
    const tempDir = path.join(this.config.tempRoot, job.id);
    await rm(tempDir, { recursive: true, force: true });
    await mkdir(tempDir, { recursive: true, mode: 0o750 });

    await this.db.setStatus(job.id, 'probing');
    const source = await probeUrl(this.config, request.url);
    await this.db.setSource(job.id, source);
    if (!request.duplicateConfirmed) {
      const duplicate = await this.db.findCompletedDownload(request, job.id);
      if (duplicate) {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setAlert(job.id, duplicateAlert(request, duplicate.id));
        return;
      }
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

    const syntheticUser = { username: job.createdBy, canWriteShared: true } as CurrentUser;
    const outputRoot = mediaRootFor(this.config, syntheticUser, request);
    const safeRoot = assertInside(outputRoot, request.destination === 'shared' ? outputRoot : this.config.usersRoot);
    await prepareDirectory(safeRoot);
    const outputFolder = await uniqueFolder(safeRoot, folderNameFor(source, request));
    assertInside(outputFolder, safeRoot);
    await this.db.setOutput(job.id, safeRoot, outputFolder);

    const title = sanitizeSegment(source.title, 'Unknown Title');
    const id = sanitizeSegment(source.id, 'NOID');
    const baseTemplate = path.join(tempDir, `${title} [${id}].%(ext)s`);
    const chapterTemplate = path.join(tempDir, 'chapters', '%(section_number)02d - %(section_title|Chapter)S.%(ext)s');
    const args = buildDownloadArgs(request, baseTemplate, chapterTemplate);
    await this.db.setStatus(job.id, 'running');
    try {
      await this.runYtDlp(job.id, args);
    } catch (error) {
      if (error instanceof Error && error.message === 'cancelled by user') {
        await rm(tempDir, { recursive: true, force: true });
        await this.db.setStatus(job.id, 'cancelled', 'cancelled by user');
        return;
      }
      throw error;
    }

    await this.db.setStatus(job.id, 'postprocessing');
    if (request.splitChapters && request.mediaType === 'audio') {
      await this.db.setProgress(job.id, { phase: 'postprocess' });
      await splitAudioChapters(tempDir, source, request.audioFormat ?? 'flac');
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

  private async runYtDlp(jobId: string, args: string[]): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const child = spawn(this.config.ytDlpPath, args, {
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      this.running.set(jobId, child);
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
}

export const validateRequest = (request: CreateJobRequest): void => {
  let parsed: URL;
  try {
    parsed = new URL(request.url);
  } catch {
    throw new Error('download URL is invalid');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('download URL must use http or https');
  }
  if (request.destination !== 'personal' && request.destination !== 'shared') {
    throw new Error('destination must be personal or shared');
  }
  if (request.mediaType === 'audio') {
    if (!request.audioFormat || !['flac', 'm4a', 'mp3', 'opus', 'wav'].includes(request.audioFormat)) {
      throw new Error('unsupported audio format');
    }
    if (request.audioQuality && !['best', 'high', 'medium', 'low'].includes(request.audioQuality)) {
      throw new Error('unsupported audio quality');
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

const killChildGroup = (child: ChildProcess, signal: NodeJS.Signals): void => {
  try {
    if (child.pid) {
      process.kill(-child.pid, signal);
    } else {
      child.kill(signal);
    }
  } catch (error) {
    const code = typeof error === 'object' && error != null && 'code' in error ? String(error.code) : '';
    if (code !== 'ESRCH') {
      throw error;
    }
  }
};

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

const splitAudioChapters = async (tempDir: string, source: ProbeResponse, audioFormat: AudioFormat): Promise<void> => {
  const input = await findDownloadedMedia(tempDir);
  const chapterDir = path.join(tempDir, 'chapters');
  await rm(chapterDir, { recursive: true, force: true });
  await mkdir(chapterDir, { recursive: true, mode: 0o750 });
  await copyFirstThumbnail(tempDir, chapterDir);

  const specs = audioChapterSpecs(source);
  for (const spec of specs) {
    const title = sanitizeSegment(spec.chapter.title, 'Chapter');
    const output = path.join(chapterDir, `${String(spec.chapter.index).padStart(2, '0')} - ${title}.${audioFormat}`);
    const args = [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-ss',
      formatSeconds(spec.start),
      '-t',
      formatSeconds(spec.duration),
      '-i',
      input,
      '-map',
      '0:a:0',
      '-map_metadata',
      '-1',
      '-map_chapters',
      '-1',
      '-vn',
      '-c:a',
      'copy',
      '-avoid_negative_ts',
      'make_zero',
      '-metadata',
      `title=${spec.chapter.title}`,
      '-metadata',
      `track=${spec.chapter.index}`,
      output,
    ];
    const result = await runCommand('ffmpeg', args, { timeoutMs: Math.max(120000, Math.ceil(spec.duration + 60) * 1000) });
    if (result.code !== 0) {
      throw new Error(result.stderr.trim() || `ffmpeg exited with code ${result.code ?? 'unknown'} while splitting chapter ${spec.chapter.index}`);
    }
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

const copyFirstThumbnail = async (tempDir: string, chapterDir: string): Promise<void> => {
  const entries = await collectFiles(tempDir);
  const thumbnail = entries.find((entry) => THUMBNAIL_EXTENSIONS.has(path.extname(entry).toLowerCase()));
  if (!thumbnail) {
    return;
  }
  await cp(thumbnail, path.join(chapterDir, 'cover.jpg'), {
    force: false,
    errorOnExist: true,
  });
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
