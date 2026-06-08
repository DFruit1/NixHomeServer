import type { IncomingHttpHeaders } from 'node:http';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
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

  return body;
};
