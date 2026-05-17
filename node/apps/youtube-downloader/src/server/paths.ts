import path from 'node:path';
import { access, mkdir } from 'node:fs/promises';
import type { AppConfig } from './config.js';
import type { CurrentUser, CreateJobRequest, ProbeResponse } from '../shared/types.js';

export const sanitizeSegment = (value: string | undefined, fallback: string): string => {
  const cleaned = (value ?? fallback)
    .replace(/[\\/]/g, ' ')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[.\s]+|[.\s]+$/g, '')
    .slice(0, 120);
  return cleaned || fallback;
};

export const dateParts = (source: ProbeResponse): { year?: string; date?: string } => {
  const raw = source.releaseDate || source.uploadDate || source.effectiveDate;
  if (!raw) {
    return {};
  }
  if (/^\d{8}$/.test(raw)) {
    return { year: raw.slice(0, 4), date: `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}` };
  }
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return { year: raw.slice(0, 4), date: raw };
  }
  if (/^\d{4}$/.test(raw)) {
    return { year: raw, date: raw };
  }
  return {};
};

export const mediaRootFor = (config: AppConfig, user: CurrentUser, request: CreateJobRequest): string => {
  if (request.destination === 'shared') {
    return request.mediaType === 'audio' ? config.sharedAudioRoot : config.sharedVideoRoot;
  }
  return request.mediaType === 'audio'
    ? path.join(config.usersRoot, user.username, 'audiobooks', 'youtube')
    : path.join(config.usersRoot, user.username, 'videos', 'youtube');
};

export const assertInside = (candidate: string, root: string): string => {
  const resolvedRoot = path.resolve(root);
  const resolvedCandidate = path.resolve(candidate);
  const prefix = resolvedRoot.endsWith(path.sep) ? resolvedRoot : `${resolvedRoot}${path.sep}`;
  if (resolvedCandidate !== resolvedRoot && !resolvedCandidate.startsWith(prefix)) {
    throw new Error(`path escaped configured root: ${candidate}`);
  }
  return resolvedCandidate;
};

export const folderNameFor = (source: ProbeResponse, request: CreateJobRequest): string[] => {
  const title = sanitizeSegment(source.title, 'Unknown Title');
  const id = sanitizeSegment(source.id, 'NOID');
  const channel = sanitizeSegment(source.channel || source.uploader, 'Unknown Channel');
  const { year, date } = dateParts(source);
  const leaf = request.includeDate && date ? `${date} - ${title} [${id}]` : `${title} [${id}]`;
  const segments: string[] = [];
  if (request.includeChannel) {
    segments.push(channel);
  }
  if (request.includeDate && year) {
    segments.push(year);
  }
  segments.push(leaf);
  return segments;
};

export const uniqueFolder = async (root: string, segments: string[]): Promise<string> => {
  const base = path.join(root, ...segments);
  for (let index = 1; index < 1000; index += 1) {
    const candidate = index === 1 ? base : `${base} (${index})`;
    try {
      await access(candidate);
    } catch {
      return candidate;
    }
  }
  throw new Error(`could not allocate unique output folder under ${root}`);
};

export const prepareDirectory = async (directory: string): Promise<void> => {
  await mkdir(directory, { recursive: true, mode: 0o775 });
};
