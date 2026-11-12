import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { buildHomepageData } from '../homepageData.js';
import { getOfflineMediaSetup } from '../offlineMedia.js';

const config: AppConfig = {
  host: '127.0.0.1', port: 8084, staticDir: tmpdir(), sudoPath: '/bin/false',
  homepage: {
    brandName: 'Test Home', domain: 'example.test', services: [], folderGuides: [], adminGuide: [],
    offlineMedia: {
      enabled: true, apiUrl: 'https://filesync-api.example.test',
      requiredAllGroups: ['users', 'files-personal-users'],
      requiredAnyGroups: ['offline-media-users'],
      fdroidRepoUrl: 'https://fdroid.example.test/fdroid/repo',
    },
  },
};

describe('File Sync setup', () => {
  it('supplies declarative setup without invoking sudo or device enrollment', async () => {
    expect(await getOfflineMediaSetup(config, { username: 'alice', groups: [] })).toEqual(config.homepage.offlineMedia);
  });

  it('keeps the setup guide restricted to baseline, Files and offline-media access', async () => {
    for (const groups of ['users', 'users offline-media-users', 'files-personal-users offline-media-users']) {
      const data = await buildHomepageData(config, {
        'x-forwarded-preferred-username': 'alice', 'x-forwarded-groups': groups,
      });
      expect(data.offlineMedia).toBeUndefined();
    }
    const data = await buildHomepageData(config, {
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'users files-personal-users offline-media-users',
    });
    expect(data.offlineMedia?.apiUrl).toBe('https://filesync-api.example.test');
    expect(data.offlineMedia?.fdroidRepoUrl).toBe('https://fdroid.example.test/fdroid/repo');
  });
});
