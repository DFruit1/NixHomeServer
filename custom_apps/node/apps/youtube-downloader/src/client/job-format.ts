import type { Job, JobStatus } from '../shared/types.js';

export const ACTIVE_STATUSES: readonly JobStatus[] = ['queued', 'alert', 'probing', 'running', 'postprocessing'];
export const IN_PROGRESS_STATUSES: readonly JobStatus[] = ['queued', 'probing', 'running', 'postprocessing'];
export const TERMINAL_FAILURE_STATUSES: readonly JobStatus[] = ['failed', 'cancelled'];

const STATUS_LABELS: Record<JobStatus, string> = {
  queued: 'Queued',
  alert: 'Needs input',
  probing: 'Checking',
  running: 'Downloading',
  postprocessing: 'Processing',
  completed: 'Done',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

export const statusLabel = (status: JobStatus): string => STATUS_LABELS[status] ?? status;

const capitalise = (value: string): string => (value ? value.charAt(0).toUpperCase() + value.slice(1) : value);

/** Human label for a quality/format option value: `best` → `Best`, `1080p` stays. */
export const optionLabel = (value: string): string => (/^\d/.test(value) ? value : capitalise(value));

/**
 * Turn a raw yt-dlp error into one readable sentence: drop the `ERROR:` and
 * `[extractor] <id>:` prefixes and collapse whitespace.
 */
export const readableError = (value: string | undefined): string | undefined => {
  const singleLine = value?.replace(/\s+/g, ' ').trim();
  if (!singleLine) {
    return undefined;
  }
  return singleLine
    .replace(/^(?:ERROR|WARNING):\s*/i, '')
    .replace(/^\[[^\]]+\]\s*(?:[A-Za-z0-9_-]{6,}:\s*)?/, '')
    .trim() || singleLine;
};

const shortWhen = (iso: string, now: number): string | undefined => {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) {
    return undefined;
  }
  const minutes = Math.max(0, Math.round((now - then) / 60000));
  if (minutes < 1) {
    return 'Just now';
  }
  if (minutes < 60) {
    return `${minutes} min ago`;
  }
  const hours = Math.round(minutes / 60);
  if (hours < 24) {
    return `${hours} h ago`;
  }
  const days = Math.round(hours / 24);
  if (days === 1) {
    return 'Yesterday';
  }
  if (days < 7) {
    return `${days} days ago`;
  }
  return new Date(then).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: days > 300 ? 'numeric' : undefined });
};

/** `Audio · FLAC · Personal · Channel · 2 h ago` (time only for finished jobs). */
export const jobDetails = (job: Job, now = Date.now()): string => {
  const format = job.request.mediaType === 'video'
    ? job.request.videoContainer?.toUpperCase()
    : job.request.audioFormat?.toUpperCase();
  const finished = !ACTIVE_STATUSES.includes(job.status);
  return [
    capitalise(job.request.mediaType),
    format,
    capitalise(job.request.destination),
    job.source?.channel,
    finished ? shortWhen(job.updatedAt, now) : undefined,
  ]
    .filter((part): part is string => Boolean(part?.trim()))
    .join(' · ');
};

export type OptionState = {
  mediaType: 'audio' | 'video';
  splitChapters: boolean;
  includeChannel: boolean;
  includeDate: boolean;
  embedAudioCoverArt: boolean;
  saveAudioToAudiobooks: boolean;
  downloadTranscript: boolean;
  autoQueueOnPaste: boolean;
};

/** Short summary of the options that differ from their defaults. */
export const optionSummary = (state: OptionState): string => {
  const audio = state.mediaType === 'audio';
  const parts = [
    !state.splitChapters && 'No chapter split',
    !state.includeChannel && 'No channel folder',
    !state.includeDate && 'No date',
    audio && !state.embedAudioCoverArt && 'No cover art',
    audio && state.saveAudioToAudiobooks && 'Audiobooks',
    state.downloadTranscript && 'Transcript',
    state.autoQueueOnPaste && 'Auto-queue on paste',
  ].filter((part): part is string => Boolean(part));
  return parts.length > 0 ? parts.join(' · ') : 'Defaults';
};
