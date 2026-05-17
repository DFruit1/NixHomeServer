import { describe, expect, it } from 'vitest';
import { assertInside, dateParts, folderNameFor, mediaRootFor, sanitizeSegment } from '../paths.js';
import type { AppConfig } from '../config.js';
import type { CurrentUser, CreateJobRequest, ProbeResponse } from '../../shared/types.js';

const config = {
  sharedVideoRoot: '/data/shared/videos/youtube',
  sharedAudioRoot: '/data/shared/audiobooks/youtube',
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
  });

  it('selects effective date parts', () => {
    expect(dateParts(source)).toEqual({ year: '2026', date: '2026-05-17' });
  });

  it('builds Jellyfin/Audiobookshelf readable folder segments', () => {
    expect(folderNameFor(source, request)).toEqual(['Original Channel', '2026', '2026-05-17 - A Useful Talk [abc123]']);
  });

  it('uses personal audiobook and video roots', () => {
    expect(mediaRootFor(config, user, request)).toBe('/data/users/dsaw/audiobooks/youtube');
    expect(mediaRootFor(config, user, { ...request, mediaType: 'video', destination: 'personal' })).toBe(
      '/data/users/dsaw/videos/youtube',
    );
  });

  it('uses shared roots for shared audio and video downloads', () => {
    expect(mediaRootFor(config, user, { ...request, destination: 'shared' })).toBe('/data/shared/audiobooks/youtube');
    expect(mediaRootFor(config, user, { ...request, mediaType: 'video', destination: 'shared' })).toBe(
      '/data/shared/videos/youtube',
    );
  });

  it('rejects paths escaping their root', () => {
    expect(() => assertInside('/data/users/dsaw/audiobooks/youtube/item', '/data/users')).not.toThrow();
    expect(() => assertInside('/data/elsewhere/item', '/data/users')).toThrow(/escaped/);
  });
});
