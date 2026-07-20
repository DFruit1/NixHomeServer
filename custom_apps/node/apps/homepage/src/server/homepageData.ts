import type { IncomingHttpHeaders } from 'node:http';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { getOfflineMediaSetup } from './offlineMedia.js';
import type { CurrentUser, HomepageData } from '../shared/types.js';

export const headersToIncomingHttpHeaders = (headers: Headers): IncomingHttpHeaders => {
  const incoming: IncomingHttpHeaders = {};
  headers.forEach((value, key) => {
    incoming[key.toLowerCase()] = value;
  });
  return incoming;
};

export const hasRequiredGroups = (
  userGroups: string[],
  requiredAllGroups?: string[],
  requiredAnyGroups?: string[],
): boolean =>
  (requiredAllGroups?.every((group) => userGroups.includes(group)) ?? true)
  && (!requiredAnyGroups?.length || requiredAnyGroups.some((group) => userGroups.includes(group)));

export const isHomepageAdmin = (config: AppConfig, user: CurrentUser): boolean =>
  (config.homepage.adminUsers ?? []).includes(user.username)
  || (config.homepage.adminGroups ?? []).some((group) => user.groups.includes(group));

export const assertFeatureAccess = (
  user: CurrentUser,
  requiredAllGroups?: string[],
  requiredAnyGroups?: string[],
): void => {
  if (!hasRequiredGroups(user.groups, requiredAllGroups, requiredAnyGroups)) {
    throw new Error('not authorised: your account does not have access to this feature');
  }
};

const describeGroup = (group: string): string => {
  const readableName = group
    .replace(/[-_]+/g, ' ')
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
  return `Grants ${readableName} access.`;
};

const fillGroupDescriptions = (groups: string[], descriptions: Record<string, string> | undefined): Record<string, string> => {
  const filledDescriptions = { ...(descriptions ?? {}) };
  for (const group of groups) {
    if (!filledDescriptions[group]?.trim()) {
      filledDescriptions[group] = describeGroup(group);
    }
  }
  return filledDescriptions;
};

export const buildHomepageData = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<HomepageData> => {
  const user = currentUserFromHeaders(headers, config.devUser);
  const isAdmin = isHomepageAdmin(config, user);
  const kanidmGroups = config.homepage.kanidmGroups ?? [];
  const {
    adminUsers: _adminUsers,
    adminGroups: _adminGroups,
    sftp,
    ...publicConfig
  } = config.homepage;
  const body: HomepageData = {
    ...publicConfig,
    adminGuide: isAdmin ? config.homepage.adminGuide : [],
    kanidmGroups: isAdmin ? kanidmGroups : undefined,
    kanidmGroupDescriptions: isAdmin ? fillGroupDescriptions(kanidmGroups, config.homepage.kanidmGroupDescriptions) : undefined,
    kanidmGroupManagement: isAdmin ? config.homepage.kanidmGroupManagement : undefined,
    canaryAdminUser: isAdmin ? config.homepage.canaryAdminUser : undefined,
    user,
    isAdmin,
    sftp: sftp ? {
      enabled: sftp.enabled,
      allowed: sftp.enabled && hasRequiredGroups(user.groups, sftp.requiredAllGroups, sftp.requiredAnyGroups),
      host: sftp.host,
      port: sftp.port,
      networkNote: sftp.networkNote,
      accessNotes: (sftp.accessNotes ?? [])
        .filter((note) => hasRequiredGroups(user.groups, note.requiredAllGroups, note.requiredAnyGroups))
        .map((note) => note.text),
    } : undefined,
  };
  body.services = body.services.filter((service) =>
    (isAdmin && !service.enabled) || hasRequiredGroups(
      body.user.groups,
      [...(service.requiredGroups ?? []), ...(service.requiredAllGroups ?? [])],
      service.requiredAnyGroups,
    ));
  body.folderGuides = body.folderGuides.filter((guide) =>
    (isAdmin && !guide.enabled) || hasRequiredGroups(
      body.user.groups,
      guide.requiredAllGroups,
      guide.requiredAnyGroups,
    )).map((guide) => ({
    ...guide,
    personalPath: hasRequiredGroups(body.user.groups, undefined, guide.personalPathRequiredAnyGroups)
      ? guide.personalPath
      : undefined,
    sharedPath: hasRequiredGroups(body.user.groups, undefined, guide.sharedPathRequiredAnyGroups)
      ? guide.sharedPath
      : undefined,
  }));

  if (body.offlineMedia?.enabled && hasRequiredGroups(
    body.user.groups,
    body.offlineMedia.requiredAllGroups,
    body.offlineMedia.requiredAnyGroups,
  )) {
    try {
      body.offlineMedia = await getOfflineMediaSetup(config, body.user);
    } catch (caught) {
      body.offlineMedia = {
        ...(body.offlineMedia as NonNullable<HomepageData['offlineMedia']>),
        serverDeviceIdError: caught instanceof Error ? caught.message : String(caught),
      };
    }
  } else {
    body.offlineMedia = undefined;
  }

  return body;
};
