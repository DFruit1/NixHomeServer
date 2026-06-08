import type { IncomingHttpHeaders } from 'node:http';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { getOfflineMusicSetup } from './offlineMusic.js';
import { getSyncthingDeviceId } from './syncthing.js';
import type { HomepageData } from '../shared/types.js';

export const headersToIncomingHttpHeaders = (headers: Headers): IncomingHttpHeaders => {
  const incoming: IncomingHttpHeaders = {};
  headers.forEach((value, key) => {
    incoming[key.toLowerCase()] = value;
  });
  return incoming;
};

export const buildHomepageData = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<HomepageData> => {
  const body: HomepageData = {
    ...config.homepage,
    kanidmGroups: config.homepage.kanidmGroups ?? [],
    user: currentUserFromHeaders(headers, config.devUser),
  };

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

  if (body.offlineMusic?.enabled) {
    try {
      body.offlineMusic = await getOfflineMusicSetup(config, body.user);
    } catch (caught) {
      body.offlineMusic = {
        ...(body.offlineMusic as NonNullable<HomepageData['offlineMusic']>),
        serverDeviceIdError: caught instanceof Error ? caught.message : String(caught),
      };
    }
  }

  return body;
};
