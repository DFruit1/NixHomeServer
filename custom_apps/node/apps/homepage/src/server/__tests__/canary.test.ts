import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { getCanaryFailure, getCanaryStatus, triggerCanary } from '../canary.js';

const headers = { 'x-forwarded-preferred-username': 'admindsaw' };

const baseConfig = (directory: string, sudoPath = '/bin/false'): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: directory,
  sudoPath,
  canaryAdminUser: 'admindsaw',
  canaryStateDir: directory,
  canaryTriggerCommand: '/nix/store/test-homepage-canary-trigger',
  homepage: { brandName: 'Test Home', domain: 'example.test', services: [], folderGuides: [], adminGuide: [] },
});

const run = (runId: string, state: 'passed' | 'failed' = 'failed') => ({
  schemaVersion: 1 as const,
  runId,
  state,
  startedAt: '2026-07-12T00:00:00.000Z',
  finishedAt: '2026-07-12T00:01:00.000Z',
  targetCount: 1,
  failureCount: state === 'failed' ? 1 : 0,
  results: [],
});

describe('service access canary admin API', () => {
  it('returns never-run when no state exists', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'homepage-canary-empty-'));
    expect(await getCanaryStatus(baseConfig(directory), headers)).toEqual({
      current: { schemaVersion: 1, state: 'never-run' },
      retainedFailures: [],
    });
  });

  it('prefers running state and returns retained failures newest first', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'homepage-canary-status-'));
    await mkdir(join(directory, 'failures'));
    await writeFile(join(directory, 'latest.json'), JSON.stringify(run('latest', 'passed')));
    await writeFile(join(directory, 'running.json'), JSON.stringify({ schemaVersion: 1, runId: 'active', state: 'running' }));
    await writeFile(join(directory, 'failures', '2026-a.json'), JSON.stringify(run('2026-a')));
    await writeFile(join(directory, 'failures', '2026-b.json'), JSON.stringify(run('2026-b')));
    const result = await getCanaryStatus(baseConfig(directory), headers);
    expect(result.current.state).toBe('running');
    expect(result.retainedFailures.map((item) => item.runId)).toEqual(['2026-b', '2026-a']);
    expect((await getCanaryFailure(baseConfig(directory), headers, '2026-a')).state).toBe('failed');
  });

  it('rejects non-admin users and path traversal', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'homepage-canary-auth-'));
    await expect(getCanaryStatus(baseConfig(directory), { 'x-forwarded-preferred-username': 'dsaw' })).rejects.toThrow('not authorised');
    await expect(getCanaryFailure(baseConfig(directory), headers, '../latest')).rejects.toThrow('invalid canary run id');
  });

  it('starts only the configured no-argument helper through noninteractive sudo', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'homepage-canary-trigger-'));
    const argsFile = join(directory, 'args.json');
    const sudo = join(directory, 'sudo');
    await writeFile(sudo, `#!/bin/sh\nprintf '%s\\n' \"$@\" > ${JSON.stringify(argsFile)}\n`);
    await chmod(sudo, 0o755);
    await expect(triggerCanary(baseConfig(directory, sudo), headers)).resolves.toEqual({ accepted: true });
    await expect((await import('node:fs/promises')).readFile(argsFile, 'utf8')).resolves.toBe('-n\n/nix/store/test-homepage-canary-trigger\n');
  });
});
