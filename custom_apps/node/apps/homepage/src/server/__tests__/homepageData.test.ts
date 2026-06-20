import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { buildHomepageData } from '../homepageData.js';

const baseConfig: AppConfig = {
  host: '127.0.0.1',
  port: 8084,
  staticDir: '.',
  sudoPath: 'sudo',
  homepage: {
    domain: 'example.test',
    services: [
      {
        id: 'files',
        name: 'Files',
        url: 'https://files.example.test',
        enabled: true,
        category: 'files',
        description: 'Files',
        loginNotes: 'Use Kanidm.',
      },
      {
        id: 'backups',
        name: 'Local Backups',
        url: 'https://kopia.example.test',
        enabled: true,
        category: 'operations',
        description: 'Kopia',
        loginNotes: 'Requires backup-admin.',
        requiredGroups: ['backup-admin'],
      },
      {
        id: 'offsite-backups',
        name: 'Offsite Backups',
        url: 'https://rclone.example.test',
        enabled: true,
        category: 'operations',
        description: 'Rclone',
        loginNotes: 'Requires backup-admin.',
        requiredGroups: ['backup-admin'],
      },
    ],
    folderGuides: [],
    adminGuide: [],
    kanidmGroups: ['backup-admin', 'media-automation-users'],
    kanidmGroupDescriptions: {
      'backup-admin': '',
    },
  },
};

describe('homepage data access filtering', () => {
  it('shows backup services to backup admins', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'alice',
      'x-auth-request-groups': 'users backup-admin',
    });

    expect(data.services.map((service) => service.id)).toEqual(['files', 'backups', 'offsite-backups']);
  });

  it('hides backup services from non-backup admins', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'bob',
      'x-auth-request-groups': 'users',
    });

    expect(data.services.map((service) => service.id)).toEqual(['files']);
  });

  it('fills missing and empty Kanidm group descriptions', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'alice',
    });

    expect(data.kanidmGroupDescriptions).toMatchObject({
      'backup-admin': 'Grants Backup Admin access.',
      'media-automation-users': 'Grants Media Automation Users access.',
    });
  });
});
