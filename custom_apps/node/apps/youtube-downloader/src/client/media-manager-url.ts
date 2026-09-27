import { isTauriRuntime, serverBaseUrl } from './api.js';
import type { MediaType } from '../shared/types.js';

export const buildMediaManagerUrl = (
  mediaType: MediaType,
  location: Pick<Location, 'hostname' | 'protocol'> = defaultLocation(),
  itemPath?: string,
): string => {
  const hostname = location.hostname.split('.');
  hostname[0] = 'media';
  const view = mediaType === 'video' ? 'videos' : 'player';
  const params = new URLSearchParams({ view });
  if (itemPath) params.set('path', itemPath);
  return `${location.protocol}//${hostname.join('.')}/?${params.toString()}`;
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
