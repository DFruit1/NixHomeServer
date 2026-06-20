import type { IncomingHttpHeaders } from 'node:http';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { getOfflineMediaSetup } from './offlineMedia.js';
import { getSyncthingDeviceId } from './syncthing.js';
import type { HomepageData } from '../shared/types.js';

export const headersToIncomingHttpHeaders = (headers: Headers): IncomingHttpHeaders => {
  const incoming: IncomingHttpHeaders = {};
  headers.forEach((value, key) => {
    incoming[key.toLowerCase()] = value;
  });
  return incoming;
};

const hasRequiredGroups = (requiredGroups: string[] | undefined, userGroups: string[]): boolean => {
  if (!requiredGroups?.length) {
    return true;
  }
  return requiredGroups.every((group) => userGroups.includes(group));
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
  const kanidmGroups = config.homepage.kanidmGroups ?? [];
  const body: HomepageData = {
    ...config.homepage,
    kanidmGroups,
    kanidmGroupDescriptions: fillGroupDescriptions(kanidmGroups, config.homepage.kanidmGroupDescriptions),
    user: currentUserFromHeaders(headers, config.devUser),
  };
  body.services = body.services.filter((service) => hasRequiredGroups(service.requiredGroups, body.user.groups));

  if (body.phoneBackup?.enabled) {
    try {
      body.phoneBackup = {
        ...body.phoneBackup,
        serverDeviceId: await getSyncthingDeviceId(config),
      };
    } catch (caught) {
      body.phoneBackup = {
        ...body.phoneBackup,
        serverDeviceIdError: caught instanceof Error ? caught.message : String(caught),
      };
    }
  }

  const legacyBody = body as HomepageData & { offlineMusic?: HomepageData['offlineMedia'] };
  body.offlineMedia = body.offlineMedia ?? legacyBody.offlineMusic;
  delete legacyBody.offlineMusic;

  if (body.offlineMedia?.enabled) {
    try {
      body.offlineMedia = await getOfflineMediaSetup(config, body.user);
    } catch (caught) {
      body.offlineMedia = {
        ...(body.offlineMedia as NonNullable<HomepageData['offlineMedia']>),
        serverDeviceIdError: caught instanceof Error ? caught.message : String(caught),
      };
    }
  }

  return body;
};
