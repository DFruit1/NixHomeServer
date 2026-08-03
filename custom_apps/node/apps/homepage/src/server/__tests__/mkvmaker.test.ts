import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { getMkvProgress } from '../mkvmaker.js';

const baseConfig = (progressFile: string): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: tmpdir(),
  sudoPath: '/bin/false',
  mkvmakerProgressFile: progressFile,
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
  },
});

const headers = { 'x-forwarded-preferred-username': 'alice' };

describe('MKV conversion progress', () => {
  it('returns a validated, redacted active conversion', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'mkvmaker-progress-'));
    try {
      const progressFile = path.join(directory, 'progress.json');
      const now = 1_800_000_000_000;
      await writeFile(progressFile, JSON.stringify({
        schemaVersion: 1,
        state: 'converting',
        updatedAt: now / 1000,
        conversions: [{
          title: 'Example Film (2001)',
          mediaKind: 'movie',
          itemName: 'Example Film (2001).mkv',
          itemIndex: 1,
          itemCount: 1,
          percent: 42.25,
          itemPercent: 42.25,
          etaSeconds: 630,
          rateFps: 31.4,
          privateQueuePath: '/do/not/expose',
        }],
      }));

      expect(await getMkvProgress(baseConfig(progressFile), headers, now)).toEqual({
        enabled: true,
        available: true,
        state: 'converting',
        updatedAt: new Date(now).toISOString(),
        conversions: [{
          title: 'Example Film (2001)',
          mediaKind: 'movie',
          itemName: 'Example Film (2001).mkv',
          itemIndex: 1,
          itemCount: 1,
          percent: 42.25,
          itemPercent: 42.25,
          etaSeconds: 630,
          rateFps: 31.4,
        }],
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('treats missing and stale snapshots as idle', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'mkvmaker-stale-'));
    try {
      const progressFile = path.join(directory, 'progress.json');
      const config = baseConfig(progressFile);
      expect(await getMkvProgress(config, headers)).toMatchObject({
        enabled: true,
        available: true,
        state: 'idle',
        conversions: [],
      });
      await writeFile(progressFile, JSON.stringify({
        schemaVersion: 1,
        state: 'converting',
        updatedAt: 1_700_000_000,
        conversions: [],
      }));
      expect(await getMkvProgress(config, headers, 1_700_001_000_000)).toMatchObject({
        available: true,
        state: 'idle',
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('passes validated queued discs through to the card', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'mkvmaker-queued-'));
    try {
      const progressFile = path.join(directory, 'progress.json');
      const now = 1_800_000_000_000;
      await writeFile(progressFile, JSON.stringify({
        schemaVersion: 1,
        state: 'idle',
        updatedAt: now / 1000,
        conversions: [],
        queued: ['Another Film 1999.iso', 'A Series S2 Disc 1.iso'],
      }));

      expect(await getMkvProgress(baseConfig(progressFile), headers, now)).toEqual({
        enabled: true,
        available: true,
        state: 'idle',
        updatedAt: new Date(now).toISOString(),
        conversions: [],
        queued: ['Another Film 1999.iso', 'A Series S2 Disc 1.iso'],
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('treats malformed queued entries as an unavailable snapshot', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'mkvmaker-queued-bad-'));
    try {
      const progressFile = path.join(directory, 'progress.json');
      await writeFile(progressFile, JSON.stringify({
        schemaVersion: 1,
        state: 'converting',
        updatedAt: 1_800_000_000,
        conversions: [{
          title: 'Example Film (2001)',
          mediaKind: 'movie',
          itemName: 'Example Film (2001).mkv',
          itemIndex: 1,
          itemCount: 1,
          percent: 1,
          itemPercent: 1,
        }],
        queued: ['fine', { not: 'a title' }],
      }));
      expect(await getMkvProgress(baseConfig(progressFile), headers)).toMatchObject({
        enabled: true,
        available: false,
        state: 'idle',
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('requires an authenticated user and rejects malformed snapshots safely', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'mkvmaker-invalid-'));
    try {
      const progressFile = path.join(directory, 'progress.json');
      const config = baseConfig(progressFile);
      await expect(getMkvProgress(config, {})).rejects.toThrow(/authenticated user/);
      await writeFile(progressFile, '{"schemaVersion":1,"state":"converting"}');
      expect(await getMkvProgress(config, headers)).toMatchObject({
        enabled: true,
        available: false,
        state: 'idle',
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
