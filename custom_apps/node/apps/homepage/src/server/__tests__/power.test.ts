import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { applyPowerSchedule, getPowerSchedule, normalisePowerScheduleValues } from '../power.js';

const adminHeaders = { 'x-forwarded-preferred-username': 'admindsaw' };
const userHeaders = { 'x-forwarded-preferred-username': 'dsaw' };

const defaults = {
  enabled: true,
  wakeTime: '10:30',
  idleWindowStartHour: 22,
  forcedWindowEndHour: 10,
};

const baseConfig = (directory: string, sudoPath = '/bin/false'): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: directory,
  sudoPath,
  powerSchedule: {
    available: true,
    stateFile: join(directory, 'schedule.json'),
    applyCommand: '/nix/store/test-homepage-power-schedule-apply',
    defaults,
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
  const directory = await mkdtemp(join(tmpdir(), 'homepage-power-'));
  configDirs.push(directory);
  return directory;
};

describe('power schedule values validation', () => {
  it('accepts a valid schedule', () => {
    expect(normalisePowerScheduleValues({ enabled: false, wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toEqual({ enabled: false, wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 10 });
  });

  it('rejects malformed wake times, hours, and windows', () => {
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '24:00', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toThrow('wakeTime must be an HH:MM time');
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '9:30', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toThrow('wakeTime must be an HH:MM time');
    expect(() => normalisePowerScheduleValues({ enabled: 'yes', wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toThrow('enabled must be a boolean');
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '10:30', idleWindowStartHour: 22.5, forcedWindowEndHour: 10 }))
      .toThrow('idleWindowStartHour must be a whole hour');
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 24 }))
      .toThrow('forcedWindowEndHour must be a whole hour');
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 23 }))
      .toThrow('forcedWindowEndHour must not be later than idleWindowStartHour');
    expect(() => normalisePowerScheduleValues({ enabled: true, wakeTime: '09:59', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toThrow('wakeTime must not fall before the end of the forced-suspend window');
    expect(() => normalisePowerScheduleValues('nope')).toThrow('must be an object');
  });

  it('accepts a wake time exactly at the forced cutoff', () => {
    expect(normalisePowerScheduleValues({ enabled: true, wakeTime: '10:00', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toMatchObject({ wakeTime: '10:00' });
  });

  it('accepts an optional day-specific skip date', () => {
    expect(normalisePowerScheduleValues({ enabled: true, wakeTime: '10:00', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .toMatchObject({ enabled: true });
  });
});

describe('power schedule admin API', () => {
  it('returns Nix defaults when no schedule file exists', async () => {
    const directory = await tempDir();
    const result = await getPowerSchedule(baseConfig(directory), adminHeaders);
    expect(result.available).toBe(true);
    expect(result.current).toEqual({ schemaVersion: 1, ...defaults });
    expect(result.defaults).toEqual(defaults);
    expect(result.warning).toBeUndefined();
  });

  it('reads a stored schedule including its update timestamp', async () => {
    const directory = await tempDir();
    const stored = { schemaVersion: 1, ...defaults, updatedAt: '2026-09-08T07:00:00Z' };
    await writeFile(join(directory, 'schedule.json'), JSON.stringify(stored));
    const result = await getPowerSchedule(baseConfig(directory), adminHeaders);
    expect(result.current).toEqual(stored);
  });

  it('falls back to defaults with a warning for an invalid stored schedule', async () => {
    const directory = await tempDir();
    await writeFile(join(directory, 'schedule.json'), '{"schemaVersion":1,"enabled":"yes"}');
    const result = await getPowerSchedule(baseConfig(directory), adminHeaders);
    expect(result.current).toEqual({ schemaVersion: 1, ...defaults });
    expect(result.warning).toContain('invalid');
  });

  it('rejects non-admin users and unconfigured servers', async () => {
    const directory = await tempDir();
    await expect(getPowerSchedule(baseConfig(directory), userHeaders)).rejects.toThrow('not authorised');
    const withoutFeature = { ...baseConfig(directory), powerSchedule: undefined };
    await expect(getPowerSchedule(withoutFeature, adminHeaders)).rejects.toThrow('not enabled');
  });

  it('applies a schedule through noninteractive sudo and reports the stored result', async () => {
    const directory = await tempDir();
    const stdinFile = join(directory, 'stdin.json');
    const sudo = join(directory, 'sudo');
    await writeFile(sudo, [
      '#!/bin/sh',
      `stdin=${JSON.stringify(stdinFile)}`,
      `state=${JSON.stringify(join(directory, 'schedule.json'))}`,
      'cat > "$stdin"',
      'jq -c \'. + {schemaVersion: 1, updatedAt: "2026-09-08T07:18:00Z"}\' "$stdin" > "$state"',
      'cat "$state"',
    ].join('\n'));
    await chmod(sudo, 0o755);
    const result = await applyPowerSchedule(baseConfig(directory, sudo), adminHeaders, {
      enabled: true,
      wakeTime: '09:45',
      idleWindowStartHour: 21,
      forcedWindowEndHour: 9,
      skipDate: '2026-09-09',
    });
    expect(result.current).toEqual({
      schemaVersion: 1,
      enabled: true,
      wakeTime: '09:45',
      idleWindowStartHour: 21,
      forcedWindowEndHour: 9,
      skipDate: '2026-09-09',
      updatedAt: '2026-09-08T07:18:00Z',
    });
    const sent = JSON.parse(await readFile(stdinFile, 'utf8')) as Record<string, unknown>;
    expect(sent).toEqual({ enabled: true, wakeTime: '09:45', idleWindowStartHour: 21, forcedWindowEndHour: 9, skipDate: '2026-09-09' });
  });

  it('surfaces helper failures and rejects invalid submissions before spawning sudo', async () => {
    const directory = await tempDir();
    await expect(applyPowerSchedule(baseConfig(directory), adminHeaders, { enabled: true, wakeTime: 'bad', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .rejects.toThrow('wakeTime must be an HH:MM time');
    await expect(applyPowerSchedule(baseConfig(directory), adminHeaders, { enabled: true, wakeTime: '10:30', idleWindowStartHour: 22, forcedWindowEndHour: 10 }))
      .rejects.toThrow('power schedule helper exited');
  });
});
