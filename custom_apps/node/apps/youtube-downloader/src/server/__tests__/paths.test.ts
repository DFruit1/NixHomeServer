import { describe, expect, it } from 'vitest';
import { mkdtemp, rm, mkdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { assertInside, allocateUniqueFolder, dateParts, folderNameFor, mediaRootFor, sanitizeSegment } from '../paths.js';
import type { AppConfig } from '../config.js';
import type { CurrentUser, CreateJobRequest, ProbeResponse } from '../../shared/types.js';

const config = {
  sharedVideoRoot: '/data/shared/_Videos/_YouTube',
  sharedAudioRoot: '/data/shared/_Music/_YouTube',
  sharedAudiobooksRoot: '/data/shared/_Audiobooks/_YouTube',
  usersRoot: '/data/users',
} as AppConfig;

const user = { username: 'dsaw' } as CurrentUser;
const source = {
  title: 'A / Useful Talk',
  id: 'abc123',
  channel: 'Original Channel',
  uploadDate: '20260517',
  chapters: [],
  isPlaylist: false,
} as ProbeResponse;

const request = {
  url: 'https://example.test/watch',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'flac',
  splitChapters: false,
  includeChannel: true,
  includeDate: true,
} as CreateJobRequest;

describe('media paths', () => {
  it('sanitizes unsafe path segments', () => {
    expect(sanitizeSegment('../bad/name', 'fallback')).toBe('bad name');
    expect(sanitizeSegment('Formstate | Liquid DnB: mix? <final>*', 'fallback')).toBe('Formstate Liquid DnB mix final');
    expect(sanitizeSegment('CON', 'fallback')).toBe('CON_');
  });

  it('selects effective date parts', () => {
    expect(dateParts(source)).toEqual({ year: '2026', date: '2026-05-17' });
  });

  it('builds Jellyfin/Audiobookshelf readable folder segments', () => {
    expect(folderNameFor(source, request)).toEqual(['Original Channel', '2026', '2026-05-17 - A Useful Talk']);
  });

  it('uses personal music, audiobook opt-in, and video roots', () => {
    expect(mediaRootFor(config, user, request)).toBe('/data/users/dsaw/_Music/_YouTube');
    expect(mediaRootFor(config, user, { ...request, saveAudioToAudiobooks: true })).toBe('/data/users/dsaw/_Audiobooks/_YouTube');
    expect(mediaRootFor(config, user, { ...request, mediaType: 'video', destination: 'personal' })).toBe(
      '/data/users/dsaw/_Videos/_YouTube',
    );
  });

  it('uses shared roots for shared audio, audiobook opt-in, and video downloads', () => {
    expect(mediaRootFor(config, user, { ...request, destination: 'shared' })).toBe('/data/shared/_Music/_YouTube');
    expect(mediaRootFor(config, user, { ...request, destination: 'shared', saveAudioToAudiobooks: true })).toBe(
      '/data/shared/_Audiobooks/_YouTube',
    );
    expect(mediaRootFor(config, user, { ...request, mediaType: 'video', destination: 'shared' })).toBe(
      '/data/shared/_Videos/_YouTube',
    );
  });

  it('rejects paths escaping their root', () => {
    expect(() => assertInside('/data/users/dsaw/_Music/_YouTube/item', '/data/users')).not.toThrow();
    expect(() => assertInside('/data/elsewhere/item', '/data/users')).toThrow(/escaped/);
  });

  it('allocates unique folders and reports collision intent', async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-path-test-'));
    const root = path.join(tempRoot, 'out');
    await mkdir(root, { recursive: true });
    const segments = ['Artist', 'Song'];

    const first = await allocateUniqueFolder(root, segments);
    expect(first.collides).toBe(false);
    expect(first.folder).toBe(path.join(root, 'Artist', 'Song'));

    await mkdir(first.folder, { recursive: true });
    const second = await allocateUniqueFolder(root, segments);
    expect(second.collides).toBe(true);
    expect(second.folder).toBe(`${path.join(root, 'Artist', 'Song')} (1)`);

    await rm(tempRoot, { recursive: true, force: true });
  });
});
