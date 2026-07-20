import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { buildHomepageData } from '../homepageData.js';

const baseConfig: AppConfig = {
  host: '127.0.0.1',
  port: 8084,
  staticDir: '.',
  sudoPath: 'sudo',
  homepage: {
    brandName: 'Test Home',
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
        id: 'files',
        name: 'Files from either access group',
        url: 'https://files.example.test',
        enabled: true,
        category: 'files',
        description: 'Files',
        loginNotes: 'Requires either file group.',
        requiredAnyGroups: ['files-browser', 'files-sftp'],
      },
    ],
    folderGuides: [{
      id: 'media',
      title: 'Media',
      enabled: true,
      serviceIds: ['files'],
      fileTypes: ['mp4'],
      personalPath: '/_Videos',
      sharedPath: '/_Shared/_Videos',
      instructions: [],
      requiredAnyGroups: ['media-users', 'files-browser'],
      personalPathRequiredAnyGroups: ['files-browser', 'files-sftp'],
      sharedPathRequiredAnyGroups: ['files-shared'],
    }],
    adminGuide: [{ title: 'Dangerous operation', detail: 'Admin inventory' }],
    adminUsers: ['alice'],
    adminGroups: ['homepage-admins'],
    kanidmGroups: ['backup-admin', 'media-automation-users'],
    kanidmGroupDescriptions: {
      'backup-admin': '',
    },
    sftp: {
      enabled: true,
      host: 'server.internal',
      port: 2022,
      networkNote: 'LAN only.',
      requiredAnyGroups: ['files-sftp', 'files-shared-users', 'usb-access', 'backup-storage-users'],
      accessNotes: [
        {
          text: 'Your SFTP root includes /_Shared as a deletion-protected shared view.',
          requiredAnyGroups: ['files-shared-users'],
        },
        {
          text: 'Your SFTP root includes /_USB for external USB storage.',
          requiredAnyGroups: ['usb-access'],
        },
        {
          text: 'Your SFTP root includes /_Backups as a read-only view.',
          requiredAnyGroups: ['backup-storage-users'],
        },
      ],
    },
  },
};

describe('homepage data access filtering', () => {
  it('shows backup services to backup admins', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'alice',
      'x-auth-request-groups': 'users backup-admin',
    });

    expect(data.services.map((service) => service.name)).toEqual(['Files', 'Local Backups']);
    expect(data.isAdmin).toBe(true);
  });

  it('hides backup services from non-backup admins', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'bob',
      'x-auth-request-groups': 'users',
    });

    expect(data.services.map((service) => service.id)).toEqual(['files']);
    expect(data.isAdmin).toBe(false);
    expect(data.adminGuide).toEqual([]);
    expect(data.kanidmGroups).toBeUndefined();
    expect(data.kanidmGroupDescriptions).toBeUndefined();
  });

  it('cannot grant operator access from an email local-part match', async () => {
    await expect(buildHomepageData(baseConfig, {
      'x-auth-request-email': 'alice@untrusted.example.test',
      'x-auth-request-groups': 'users',
    })).rejects.toThrow('missing authenticated user header');
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

  it('honours any-of access and hides inaccessible chroot paths', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'carol',
      'x-auth-request-groups': 'media-users',
    });

    expect(data.services.map((service) => service.name)).toEqual(['Files']);
    expect(data.folderGuides).toEqual([expect.objectContaining({
      id: 'media',
      personalPath: undefined,
      sharedPath: undefined,
    })]);

    const fileUser = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'dave',
      'x-auth-request-groups': 'files-browser files-shared',
    });
    expect(fileUser.services.map((service) => service.name)).toEqual(['Files', 'Files from either access group']);
    expect(fileUser.folderGuides[0]).toMatchObject({
      personalPath: '/_Videos',
      sharedPath: '/_Shared/_Videos',
    });
  });

  it('allows an evaluated admin group as well as the configured operator', async () => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'dana',
      'x-auth-request-groups': 'homepage-admins',
    });
    expect(data.isAdmin).toBe(true);
    expect(data.adminGuide).toHaveLength(1);
  });

  it.each([
    ['shared-only', 'files-shared-users', '/_Shared'],
    ['USB-only', 'usb-access', '/_USB'],
    ['backup-storage-only', 'backup-storage-users', '/_Backups'],
  ])('allows %s users to manage an SFTP key and shows only their relevant view guidance', async (_role, group, visiblePath) => {
    const data = await buildHomepageData(baseConfig, {
      'x-auth-request-preferred-username': 'role-only-user',
      'x-auth-request-groups': group,
    });

    expect(data.sftp?.allowed).toBe(true);
    expect(data.sftp?.accessNotes).toHaveLength(1);
    expect(data.sftp?.accessNotes[0]).toContain(visiblePath);
  });
});
