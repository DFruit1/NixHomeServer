import type { KanidmGroupManagementSource } from './types.js';

export type AccessChangeAction = 'grant' | 'revoke';
export type ConfiguredMembershipSource = Exclude<KanidmGroupManagementSource, 'manual'>;

export type ConfiguredMembershipSelection = {
  source: ConfiguredMembershipSource;
  groups: string[];
};

const configuredMembershipSources: ConfiguredMembershipSource[] = [
  'identity.appUsers',
  'backupAccess.adminUsers',
  'backupAccess.storageUsers',
];

export const buildMembershipCommands = (
  groups: string[],
  userArg: string,
  action: AccessChangeAction,
): string[] => {
  if (groups.length === 0) {
    return [];
  }
  const quotedGroups = groups
    .map((group) => group.trim())
    .filter((group) => group.length > 0)
    .sort()
    .map((group) => `'${group.replace(/'/g, `'\\''`)}'`)
    .join(' ');
  const command = action === 'grant' ? 'add-members' : 'remove-members';
  return [`for group in ${quotedGroups}; do`, `  kanidm group ${command} "$group" ${userArg}`, 'done'];
};

export const configuredMembershipSelections = (
  groups: string[],
  management: Record<string, KanidmGroupManagementSource>,
): ConfiguredMembershipSelection[] =>
  configuredMembershipSources.flatMap((source) => {
    const sourceGroups = groups.filter((group) => management[group] === source).sort();
    return sourceGroups.length === 0 ? [] : [{ source, groups: sourceGroups }];
  });

export const configuredMembershipEdit = (
  source: ConfiguredMembershipSource,
  action: AccessChangeAction,
  member: string,
): string => {
  if (action === 'grant') {
    return `add ${member} once to ${source}`;
  }
  if (source === 'identity.appUsers') {
    return `remove ${member} from identity.appUsers and identity.appAdminUsers wherever present`;
  }
  return `remove ${member} from ${source}`;
};

export const configuredMembershipEffect = (
  source: ConfiguredMembershipSource,
  action: AccessChangeAction,
): string => {
  if (source === 'identity.appUsers') {
    return action === 'grant'
      ? 'This grants every enabled default app group above, not only one app.'
      : 'This revokes the enabled default app bundle; removing identity.appAdminUsers also removes configured application-admin access.';
  }
  if (source === 'backupAccess.adminUsers') {
    return action === 'grant'
      ? 'This grants Kopia administration and automatically includes backup storage access.'
      : 'This revokes Kopia administration and its inherited backup storage access.';
  }
  return action === 'grant'
    ? 'This grants read-only backup repository access, not Kopia administration.'
    : 'This revokes read-only backup repository access without changing Kopia administration.';
};
