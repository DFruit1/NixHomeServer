import { describe, expect, it } from 'vitest';
import {
  buildMembershipCommands,
  configuredMembershipEdit,
  configuredMembershipEffect,
  configuredMembershipSelections,
} from '../../shared/admin-access.js';

describe('Homepage admin access guidance', () => {
  it('generates distinct manual grant and revoke commands', () => {
    expect(buildMembershipCommands(['files-sftp-users'], "'alice'", 'grant')).toEqual([
      "for group in 'files-sftp-users'; do",
      '  kanidm group add-members "$group" \'alice\'',
      'done',
    ]);
    expect(buildMembershipCommands(['files-sftp-users'], "'alice'", 'revoke')).toEqual([
      "for group in 'files-sftp-users'; do",
      '  kanidm group remove-members "$group" \'alice\'',
      'done',
    ]);
  });

  it('groups repository-managed memberships by their actual vars.nix source', () => {
    const management = {
      'photos-users': 'identity.appUsers',
      'documents-users': 'identity.appUsers',
      'backup-admin': 'backupAccess.adminUsers',
      'files-sftp-users': 'manual',
    } as const;
    expect(configuredMembershipSelections(
      ['photos-users', 'files-sftp-users', 'backup-admin', 'documents-users'],
      management,
    )).toEqual([
      { source: 'identity.appUsers', groups: ['documents-users', 'photos-users'] },
      { source: 'backupAccess.adminUsers', groups: ['backup-admin'] },
    ]);
  });

  it('explains safe repository-managed revocation, including inherited app admins', () => {
    expect(configuredMembershipEdit('identity.appUsers', 'revoke', '"alice"')).toBe(
      'remove "alice" from identity.appUsers and identity.appAdminUsers wherever present',
    );
    expect(configuredMembershipEffect('identity.appUsers', 'revoke')).toMatch(/revokes the enabled default app bundle/);
    expect(configuredMembershipEffect('backupAccess.adminUsers', 'revoke')).toMatch(/inherited backup storage access/);
    expect(configuredMembershipEffect('backupAccess.storageUsers', 'revoke')).toMatch(/without changing Kopia administration/);
  });
});
