import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { getAdminDashboard } from '../adminDashboard.js';

const adminHeaders = { 'x-forwarded-preferred-username': 'admindsaw' };
const userHeaders = { 'x-forwarded-preferred-username': 'dsaw' };

const baseConfig = (directory: string, enabled = true): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: directory,
  sudoPath: '/bin/false',
  adminDashboard: enabled ? { available: true, statusFile: join(directory, 'status.json') } : undefined,
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    adminUsers: ['admindsaw'],
  },
});

const directories: string[] = [];

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

const tempDir = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), 'homepage-admin-dashboard-'));
  directories.push(directory);
  return directory;
};

const generatedAt = (secondsAgo: number): string =>
  new Date(Date.now() - secondsAgo * 1000).toISOString();

type CollectorOverrides = {
  kopiaSnapshot?: unknown;
  kopiaVerify?: unknown;
  logicalBackup?: unknown;
  offsiteSync?: unknown;
  zfsSnapshots?: unknown;
};

const collectorStatus = (overrides: CollectorOverrides = {}): Record<string, unknown> => ({
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  kopiaSnapshot: {
    completedAt: generatedAt(2 * 60 * 60),
    ageSeconds: 2 * 60 * 60,
    maxAgeSeconds: 36 * 60 * 60,
  },
  kopiaVerify: {
    completedAt: generatedAt(3 * 24 * 60 * 60),
    ageSeconds: 3 * 24 * 60 * 60,
    maxAgeSeconds: 8 * 24 * 60 * 60,
  },
  logicalBackup: {
    generation: '20261024T031500-4211',
    completedAt: generatedAt(3 * 60 * 60),
    ageSeconds: 3 * 60 * 60,
    maxAgeSeconds: 36 * 60 * 60,
    expected: [
      { name: 'kanidm.sqlite', kind: 'sqlite' },
      { name: 'paperless.sql', kind: 'postgresql' },
    ],
    dumps: [
      {
        name: 'kanidm.sqlite',
        kind: 'sqlite',
        bytes: 4_194_304,
        sha256: 'a'.repeat(64),
        integrityCheck: 'ok',
        createdAt: generatedAt(3 * 60 * 60),
      },
      {
        name: 'paperless.sql',
        kind: 'postgresql',
        bytes: 8_388_608,
        sha256: 'b'.repeat(64),
        integrityCheck: 'ok',
        createdAt: generatedAt(3 * 60 * 60),
      },
    ],
  },
  offsiteSync: {
    state: 'success',
    reason: 'mirror_verified',
    message: 'MEGA mirror verified',
    completedAt: generatedAt(4 * 60 * 60),
    ageSeconds: 4 * 60 * 60,
    maxAgeSeconds: 26 * 60 * 60,
    repositoryBytes: 1024,
    limitBytes: 2048,
  },
  zfsSnapshots: {
    pool: 'tank',
    health: 'ONLINE',
    staleDatasets: 0,
    newestAgeSeconds: 60 * 60,
    maxAgeSeconds: 48 * 60 * 60,
  },
  ...overrides,
});

const writeStatus = async (directory: string, status: unknown): Promise<void> => {
  await writeFile(join(directory, 'status.json'), typeof status === 'string' ? status : JSON.stringify(status));
};

const widget = (response: Awaited<ReturnType<typeof getAdminDashboard>>, id: string) => {
  const found = response.widgets.find((candidate) => candidate.id === id);
  if (!found) throw new Error(`widget ${id} is missing`);
  return found;
};

describe('admin dashboard access', () => {
  it('refuses non-admins', async () => {
    const directory = await tempDir();
    await expect(getAdminDashboard(baseConfig(directory), userHeaders)).rejects.toThrow('not authorised');
  });

  it('reports the feature as unavailable when the server has no cached status file configured', async () => {
    const directory = await tempDir();
    const response = await getAdminDashboard(baseConfig(directory, false), adminHeaders);
    expect(response.available).toBe(false);
    expect(response.reason).toContain('not enabled');
    expect(response.widgets).toEqual([]);
  });

  it('reports a missing cached status instead of failing the page', async () => {
    const directory = await tempDir();
    const response = await getAdminDashboard(baseConfig(directory), adminHeaders);
    expect(response.available).toBe(false);
    expect(response.reason).toContain('no cached dashboard status');
  });

  it('rejects cached status that is not valid JSON', async () => {
    const directory = await tempDir();
    await writeStatus(directory, '{not json');
    const response = await getAdminDashboard(baseConfig(directory), adminHeaders);
    expect(response.available).toBe(false);
    expect(response.reason).toContain('could not be read');
  });

  it('rejects cached status with an unsupported schema version', async () => {
    const directory = await tempDir();
    await writeStatus(directory, { schemaVersion: 99, generatedAt: new Date().toISOString() });
    const response = await getAdminDashboard(baseConfig(directory), adminHeaders);
    expect(response.available).toBe(false);
    expect(response.reason).toContain('schema');
  });
});

describe('admin dashboard backup freshness widget', () => {
  it('reports every source as healthy when all are fresh', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus());
    const response = await getAdminDashboard(baseConfig(directory), adminHeaders);
    expect(response.available).toBe(true);
    expect(response.generatedAgeSeconds).toBeGreaterThanOrEqual(0);
    const freshness = widget(response, 'backup-freshness');
    expect(freshness.state).toBe('ok');
    expect(freshness.rows.map((row) => row.label)).toEqual([
      'Kopia snapshot',
      'Kopia deep verify',
      'Logical backup',
      'Offsite MEGA sync',
      'ZFS snapshots',
    ]);
    expect(freshness.rows.every((row) => row.state === 'ok')).toBe(true);
    expect(freshness.summary).toContain('within');
  });

  it('marks a stale Kopia snapshot as critical and names the age', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({
      kopiaSnapshot: {
        completedAt: generatedAt(48 * 60 * 60),
        ageSeconds: 48 * 60 * 60,
        maxAgeSeconds: 36 * 60 * 60,
      },
    }));
    const freshness = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    expect(freshness.state).toBe('critical');
    const row = freshness.rows.find((candidate) => candidate.label === 'Kopia snapshot');
    expect(row?.state).toBe('critical');
    expect(row?.value).toContain('2d');
    expect(freshness.summary).toContain('Kopia snapshot');
  });

  it('warns while a source is approaching its freshness limit', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({
      logicalBackup: {
        generation: '20261024T031500-4211',
        completedAt: generatedAt(30 * 60 * 60),
        ageSeconds: 30 * 60 * 60,
        maxAgeSeconds: 36 * 60 * 60,
        expected: [{ name: 'kanidm.sqlite', kind: 'sqlite' }],
        dumps: [{
          name: 'kanidm.sqlite',
          kind: 'sqlite',
          bytes: 1024,
          sha256: 'a'.repeat(64),
          integrityCheck: 'ok',
          createdAt: generatedAt(30 * 60 * 60),
        }],
      },
    }));
    const freshness = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    const row = freshness.rows.find((candidate) => candidate.label === 'Logical backup');
    expect(row?.state).toBe('warn');
  });

  it('treats a missing marker as critical rather than unknown', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({ kopiaSnapshot: { error: 'missing', detail: 'no marker' } }));
    const freshness = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    const row = freshness.rows.find((candidate) => candidate.label === 'Kopia snapshot');
    expect(row?.state).toBe('critical');
    expect(row?.value).toContain('no successful');
  });

  it('reports a blocked offsite mirror as critical and a stale success as a warning', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({
      offsiteSync: {
        state: 'blocked',
        reason: 'capacity',
        message: 'Remote quota exceeded',
        completedAt: generatedAt(60 * 60),
        ageSeconds: 60 * 60,
        maxAgeSeconds: 26 * 60 * 60,
        repositoryBytes: 4096,
        limitBytes: 2048,
      },
    }));
    const blocked = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    const blockedRow = blocked.rows.find((candidate) => candidate.label === 'Offsite MEGA sync');
    expect(blockedRow?.state).toBe('critical');
    expect(blockedRow?.value).toContain('Remote quota exceeded');

    await writeStatus(directory, collectorStatus({
      offsiteSync: {
        state: 'success',
        reason: 'mirror_verified',
        message: 'MEGA mirror verified',
        completedAt: generatedAt(30 * 60 * 60),
        ageSeconds: 30 * 60 * 60,
        maxAgeSeconds: 26 * 60 * 60,
        repositoryBytes: 1024,
        limitBytes: 2048,
      },
    }));
    const stale = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    expect(stale.rows.find((candidate) => candidate.label === 'Offsite MEGA sync')?.state).toBe('warn');
  });

  it('omits sources that the server reports as disabled', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({
      offsiteSync: { disabled: true },
      zfsSnapshots: { disabled: true },
    }));
    const freshness = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    expect(freshness.rows.map((row) => row.label)).toEqual([
      'Kopia snapshot',
      'Kopia deep verify',
      'Logical backup',
    ]);
  });

  it('flags a degraded ZFS pool', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({
      zfsSnapshots: {
        pool: 'tank',
        health: 'DEGRADED',
        staleDatasets: 2,
        newestAgeSeconds: 60 * 60,
        maxAgeSeconds: 48 * 60 * 60,
      },
    }));
    const freshness = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'backup-freshness');
    const row = freshness.rows.find((candidate) => candidate.label === 'ZFS snapshots');
    expect(row?.state).toBe('critical');
    expect(row?.value).toContain('DEGRADED');
  });
});

describe('admin dashboard dump verification widget', () => {
  it('confirms every expected dump with integrity and size', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus());
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.state).toBe('ok');
    expect(verification.summary).toContain('2/2');
    expect(verification.rows.map((row) => row.label)).toEqual(['kanidm.sqlite', 'paperless.sql']);
    expect(verification.rows[1]?.value).toContain('8.0\u00A0MiB');
    expect(verification.rows[0]?.value).toContain('integrity\u00A0ok');
  });

  it('alerts when a configured dump is missing from the generation', async () => {
    const directory = await tempDir();
    const status = collectorStatus();
    const logical = status.logicalBackup as Record<string, unknown>;
    logical.dumps = [(logical.dumps as unknown[])[0]];
    await writeStatus(directory, status);
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.state).toBe('critical');
    const missing = verification.rows.find((row) => row.label === 'paperless.sql');
    expect(missing?.state).toBe('critical');
    expect(missing?.value).toContain('missing');
    expect(verification.summary).toContain('paperless.sql');
  });

  it('alerts when a dump failed its integrity check', async () => {
    const directory = await tempDir();
    const status = collectorStatus();
    const logical = status.logicalBackup as Record<string, unknown>;
    (logical.dumps as Array<Record<string, unknown>>)[0].integrityCheck = 'failed';
    await writeStatus(directory, status);
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.state).toBe('critical');
    expect(verification.rows[0]?.value).toContain('integrity\u00A0failed');
  });

  it('warns when the generation predates per-dump verification data', async () => {
    const directory = await tempDir();
    const status = collectorStatus();
    const logical = status.logicalBackup as Record<string, unknown>;
    delete logical.expected;
    delete logical.dumps;
    await writeStatus(directory, status);
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.state).toBe('warn');
    expect(verification.summary).toContain('no per-dump');
  });

  it('is critical when no logical backup generation exists', async () => {
    const directory = await tempDir();
    await writeStatus(directory, collectorStatus({ logicalBackup: { error: 'missing', detail: 'no current link' } }));
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.state).toBe('critical');
    expect(verification.summary).toContain('No logical backup');
  });

  it('ignores malformed and oversized dump records instead of echoing them', async () => {
    const directory = await tempDir();
    const status = collectorStatus();
    const logical = status.logicalBackup as Record<string, unknown>;
    logical.dumps = [
      ...(logical.dumps as unknown[]),
      { name: 'x'.repeat(400), kind: 'sqlite', bytes: 1, sha256: 'nothex', integrityCheck: 'ok' },
      { name: 'kanidm.sqlite', kind: 'sqlite', bytes: -5, sha256: 'a'.repeat(64), integrityCheck: 'ok' },
      'junk',
    ];
    await writeStatus(directory, status);
    const verification = widget(await getAdminDashboard(baseConfig(directory), adminHeaders), 'dump-verification');
    expect(verification.rows.some((row) => row.label.length > 128)).toBe(false);
    expect(verification.rows.filter((row) => row.label === 'kanidm.sqlite')).toHaveLength(1);
  });
});
