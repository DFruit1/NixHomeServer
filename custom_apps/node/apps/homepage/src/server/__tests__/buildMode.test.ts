import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { applyBuildMode, getBuildMode, normaliseBuildMode } from '../buildMode.js';

const adminHeaders = { 'x-forwarded-preferred-username': 'admindsaw' };
const userHeaders = { 'x-forwarded-preferred-username': 'dsaw' };

const baseConfig = (directory: string, sudoPath = '/bin/false'): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: directory,
  sudoPath,
  buildMode: {
    available: true,
    stateFile: join(directory, 'build-mode.json'),
    applyCommand: '/nix/store/test-homepage-nix-build-mode-apply',
    defaultMode: 'maximum-effort',
  },
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    adminUsers: ['admindsaw'],
  },
});

const configDirs: string[] = [];

afterEach(async () => {
  await Promise.all(configDirs.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

const tempDir = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), 'homepage-build-mode-'));
  configDirs.push(directory);
  return directory;
};

describe('nix build mode validation', () => {
  it('accepts the four known modes', () => {
    for (const mode of ['local', 'remote', 'balanced', 'maximum-effort'] as const) {
      expect(normaliseBuildMode(mode)).toBe(mode);
    }
  });

  it('rejects unknown modes', () => {
    expect(() => normaliseBuildMode('turbo')).toThrow('buildMode must be one of');
    expect(() => normaliseBuildMode(undefined)).toThrow('buildMode must be one of');
    expect(() => normaliseBuildMode(42)).toThrow('buildMode must be one of');
  });
});

describe('nix build mode admin API', () => {
  it('reports the vars.nix default when nothing is stored', async () => {
    const directory = await tempDir();
    const result = await getBuildMode(baseConfig(directory), adminHeaders);
    expect(result.available).toBe(true);
    expect(result.current).toEqual({ buildMode: 'maximum-effort' });
    expect(result.defaultMode).toBe('maximum-effort');
    expect(result.modes.map((mode) => mode.value)).toEqual(['local', 'remote', 'balanced', 'maximum-effort']);
  });

  it('reads a stored build mode and timestamp', async () => {
    const directory = await tempDir();
    await writeFile(join(directory, 'build-mode.json'), JSON.stringify({
      schemaVersion: 1,
      buildMode: 'balanced',
      updatedAt: '2026-09-08T20:00:00Z',
    }));
    const result = await getBuildMode(baseConfig(directory), adminHeaders);
    expect(result.current).toEqual({ buildMode: 'balanced', updatedAt: '2026-09-08T20:00:00Z' });
  });

  it('falls back to the default with a warning for an invalid stored mode', async () => {
    const directory = await tempDir();
    await writeFile(join(directory, 'build-mode.json'), '{"schemaVersion":1,"buildMode":"turbo"}');
    const result = await getBuildMode(baseConfig(directory), adminHeaders);
    expect(result.current).toEqual({ buildMode: 'maximum-effort' });
    expect(result.warning).toContain('invalid');
  });

  it('rejects non-admin users and unconfigured servers', async () => {
    const directory = await tempDir();
    await expect(getBuildMode(baseConfig(directory), userHeaders)).rejects.toThrow('not authorised');
    const withoutFeature = { ...baseConfig(directory), buildMode: undefined };
    await expect(getBuildMode(withoutFeature, adminHeaders)).rejects.toThrow('not enabled');
  });

  it('applies a build mode through noninteractive sudo', async () => {
    const directory = await tempDir();
    const stdinFile = join(directory, 'stdin.json');
    const sudo = join(directory, 'sudo');
    await writeFile(sudo, [
      '#!/bin/sh',
      `stdin=${JSON.stringify(stdinFile)}`,
      `state=${JSON.stringify(join(directory, 'build-mode.json'))}`,
      'cat > "$stdin"',
      'jq -c \'{schemaVersion: 1, buildMode: .buildMode, updatedAt: "2026-09-08T20:30:00Z"}\' "$stdin" > "$state"',
      'cat "$state"',
    ].join('\n'));
    await chmod(sudo, 0o755);
    const result = await applyBuildMode(baseConfig(directory, sudo), adminHeaders, { buildMode: 'balanced' });
    expect(result.current).toEqual({ buildMode: 'balanced', updatedAt: '2026-09-08T20:30:00Z' });
    const sent = JSON.parse(await readFile(stdinFile, 'utf8')) as Record<string, unknown>;
    expect(sent).toEqual({ buildMode: 'balanced' });
  });

  it('rejects invalid submissions before spawning sudo', async () => {
    const directory = await tempDir();
    await expect(applyBuildMode(baseConfig(directory), adminHeaders, { buildMode: 'turbo' }))
      .rejects.toThrow('buildMode must be one of');
    await expect(applyBuildMode(baseConfig(directory), adminHeaders, {}))
      .rejects.toThrow('buildMode must be one of');
  });
});
