import { isTauriRuntime, serverBaseUrl } from './api.js';
import type { MediaType } from '../shared/types.js';

export const buildMediaManagerUrl = (
  mediaType: MediaType,
  location: Pick<Location, 'hostname' | 'protocol'> = defaultLocation(),
): string => {
  const hostname = location.hostname.split('.');
  hostname[0] = 'media';
  const view = mediaType === 'video' ? 'videos' : 'player';
  return `${location.protocol}//${hostname.join('.')}/?view=${view}`;
};

const defaultLocation = (): Pick<Location, 'hostname' | 'protocol'> => {
  if (isTauriRuntime()) {
    try {
      const server = new URL(serverBaseUrl());
      if (server.hostname) {
        return { hostname: server.hostname, protocol: server.protocol };
      }
    } catch {
      // Fall through to the page origin when the configured server URL is invalid.
    }
  }
  return window.location;
};
