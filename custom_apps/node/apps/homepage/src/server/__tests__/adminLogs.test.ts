import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { getAdminLogs, getRecentErrorSummary } from '../adminLogs.js';

const adminHeaders = { 'x-forwarded-preferred-username': 'admindsaw' };
const userHeaders = { 'x-forwarded-preferred-username': 'dsaw' };
const directories: string[] = [];

const setup = async (
  cache: unknown,
  units = [
    { id: 'homepage', label: 'Homepage', unit: 'homepage.service' },
    { id: 'service-access-canary', label: 'Service access canary', unit: 'homepage-canary.service' },
  ],
) => {
  const directory = await mkdtemp(join(tmpdir(), 'homepage-admin-logs-'));
  directories.push(directory);
  const cacheFile = join(directory, 'logs.json');
  const manifestFile = join(directory, 'units.json');
  await writeFile(cacheFile, JSON.stringify(cache));
  await writeFile(manifestFile, JSON.stringify({ schemaVersion: 1, units }));
  const config: AppConfig = {
    host: '127.0.0.1', port: 8084, staticDir: directory, sudoPath: '/bin/false',
    adminLogs: { available: true, statusFile: cacheFile, unitsFile: manifestFile },
    homepage: {
      brandName: 'Test Home', domain: 'example.test', services: [], folderGuides: [], adminGuide: [],
      adminUsers: ['admindsaw'],
    },
  };
  return { config, cacheFile, manifestFile };
};

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

const now = Date.now();
const event = (offsetMs = 0, priority = 3) => ({
  timestamp: new Date(now - offsetMs).toISOString(),
  priority,
  message: 'Journal error event; message withheld',
});
const report = (entries: unknown[] = [event()]) => ({
  schemaVersion: 1,
  generatedAt: new Date(now).toISOString(),
  horizonSeconds: 86400,
  units: [
    { unit: 'homepage.service', state: 'available', reasonCode: null, truncated: false, entries },
    { unit: 'homepage-canary.service', state: 'available', reasonCode: null, truncated: false, entries: [] },
  ],
});

describe('admin log cache access', () => {
  it('requires an administrator before opening either configured file', async () => {
    const { config } = await setup(report());
    await expect(getAdminLogs(config, userHeaders, { unit: 'homepage' })).rejects.toThrow('not authorised');
    await expect(getRecentErrorSummary(config, userHeaders)).rejects.toThrow('not authorised');
  });

  it('returns a metadata-only filtered response with freshness from the cache', async () => {
    const { config } = await setup(report([event(1_000, 1), event(2_000, 3)]));
    const response = await getAdminLogs(config, adminHeaders, { unit: 'homepage', sinceSeconds: 3600, query: 'withheld', limit: 10 });
    expect(response).toMatchObject({
      schemaVersion: 1, state: 'available', unit: 'homepage.service', windowSeconds: 3600,
      privacyMode: 'metadata-only', truncated: false, reasonCode: null,
    });
    expect(response.entries).toHaveLength(2);
    expect(response.entries.map((entry) => entry.priority)).toEqual([1, 3]);
    expect(response.sourceGeneratedAt).toBe(report().generatedAt);
    expect(response.entries.every((entry) => entry.message === 'Journal error event; message withheld')).toBe(true);
    expect(JSON.stringify(response)).not.toMatch(/secret|token/i);
  });

  it('rejects unknown services rather than reading a cached disabled unit', async () => {
    const { config } = await setup(report());
    await expect(getAdminLogs(config, adminHeaders, { unit: 'other.service' })).rejects.toThrow('invalid');
  });

  it('returns an unavailable envelope for missing files without exposing paths', async () => {
    const { config, cacheFile } = await setup(report());
    await rm(cacheFile);
    const response = await getAdminLogs(config, adminHeaders, { unit: 'homepage' });
    expect(response.state).toBe('unavailable');
    expect(JSON.stringify(response)).not.toContain(cacheFile);
  });

  it('returns an invalid envelope for non-regular, symlinked and oversized caches', async () => {
    const nonRegular = await setup(report());
    await rm(nonRegular.cacheFile);
    await mkdir(nonRegular.cacheFile);
    expect((await getAdminLogs(nonRegular.config, adminHeaders, { unit: 'homepage' })).state).toBe('invalid');

    const symlinked = await setup(report());
    const original = await readFile(symlinked.cacheFile);
    const target = join(symlinked.config.adminLogs!.statusFile, '..', 'outside.json');
    await writeFile(target, original);
    await rm(symlinked.cacheFile);
    await symlink(target, symlinked.cacheFile);
    expect((await getAdminLogs(symlinked.config, adminHeaders, { unit: 'homepage' })).state).toBe('unavailable');

    const oversized = await setup(report());
    await writeFile(oversized.cacheFile, Buffer.alloc(131073, 0x20));
    expect((await getAdminLogs(oversized.config, adminHeaders, { unit: 'homepage' })).state).toBe('invalid');
  });

  it('returns stale and invalid cache states without leaking source data', async () => {
    const staleReport = {
      ...report([event(20 * 60_000)]),
      generatedAt: new Date(now - 16 * 60_000).toISOString(),
    };
    const staleSetup = await setup(staleReport);
    const stale = await getAdminLogs(staleSetup.config, adminHeaders, { unit: 'homepage' });
    expect(stale).toMatchObject({ state: 'stale', reasonCode: 'cache-stale', entries: [] });
    expect((await getRecentErrorSummary(staleSetup.config, adminHeaders)).units[0]).toMatchObject({ state: 'stale', count: 0 });

    const invalidSetup = await setup({ ...report(), schemaVersion: 2 });
    const invalid = await getAdminLogs(invalidSetup.config, adminHeaders, { unit: 'homepage' });
    expect(invalid).toMatchObject({ state: 'invalid', reasonCode: 'cache-invalid', entries: [] });
  });

  it('sorts fractional timestamps with offsets by their actual instant, then priority', async () => {
    const base = new Date(now - 2000).toISOString();
    const equivalentOffset = new Date(Date.parse(base) + 3_600_000).toISOString().replace('Z', '+01:00');
    const entries = [
      { timestamp: base, priority: 3, message: 'Journal error event; message withheld' },
      { timestamp: equivalentOffset, priority: 1, message: 'Journal error event; message withheld' },
    ];
    const { config } = await setup(report(entries));
    const response = await getAdminLogs(config, adminHeaders, { unit: 'homepage' });
    expect(response.state).toBe('available');
    expect(response.entries.map((entry: { priority: number }) => entry.priority)).toEqual([1, 3]);
  });

  it('rejects malformed filter types and unsafe query controls', async () => {
    const { config } = await setup(report());
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', limit: true })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', sinceSeconds: 1.5 })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', query: 'x\u202ey' })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', query: 'x\u0085y' })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', query: '\ud800' })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', query: 'x'.repeat(129) })).rejects.toThrow('invalid');
    await expect(getAdminLogs(config, adminHeaders, { unit: 'homepage', query: '😀'.repeat(33) })).rejects.toThrow('invalid');
  });

  it('clamps safe integer filters and applies literal filtering before the limit', async () => {
    const { config } = await setup(report([event(1000, 1), event(2000, 2), event(3000, 3)]));
    const clamped = await getAdminLogs(config, adminHeaders, { unit: 'homepage', sinceSeconds: 0, limit: 0 });
    expect(clamped).toMatchObject({ windowSeconds: 60, entries: [expect.objectContaining({ priority: 1 })] });
    const unbounded = await getAdminLogs(config, adminHeaders, { unit: 'homepage', sinceSeconds: 999999, limit: 999 });
    expect(unbounded.windowSeconds).toBe(86400);
    expect(unbounded.entries).toHaveLength(3);
    const literal = await getAdminLogs(config, adminHeaders, { unit: 'homepage', query: '[', limit: 1 });
    expect(literal.entries).toEqual([]);
    expect(literal.reasonCode).toBe('no-events-observed');
  });

  it('treats a valid fresh empty scan as available without claiming service health', async () => {
    const { config } = await setup(report([]));
    const response = await getAdminLogs(config, adminHeaders, { unit: 'homepage' });
    expect(response.state).toBe('available');
    expect(response.entries).toEqual([]);
    expect(response.reasonCode).toBe('no-events-observed');
  });
});
