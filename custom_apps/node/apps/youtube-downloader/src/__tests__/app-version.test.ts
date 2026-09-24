import { describe, expect, it } from 'vitest';
import packageJson from '../../package.json';
import { installedAppDate, installedAppVersion, installedVersionLabel, isNewerVersion } from '../client/app-version.js';

describe('installed version', () => {
  it('matches the package.json release the bundle was built from', () => {
    expect(installedAppVersion).toBe(packageJson.version);
    expect(installedAppDate).toBe(packageJson.versionDate);
    expect(installedVersionLabel).toContain(packageJson.version);
  });
});

describe('isNewerVersion', () => {
  it('compares dotted numeric segments', () => {
    expect(isNewerVersion('0.2.0', '0.1.0')).toBe(true);
    expect(isNewerVersion('0.1.0', '0.2.0')).toBe(false);
    expect(isNewerVersion('1.0.0', '0.9.9')).toBe(true);
    expect(isNewerVersion('0.10.0', '0.9.0')).toBe(true);
    expect(isNewerVersion('1.2.3', '1.2.3')).toBe(false);
  });

  it('treats missing segments as zero and tolerates non-numeric parts', () => {
    expect(isNewerVersion('1.0', '1.0.0')).toBe(false);
    expect(isNewerVersion('1.0.1', '1.0')).toBe(true);
    expect(isNewerVersion('2.0.0-beta', '1.9.9')).toBe(true);
  });
});
