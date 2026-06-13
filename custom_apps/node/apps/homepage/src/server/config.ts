import { readFileSync } from 'node:fs';
import type { AdminStep, FolderGuide, OfflineMediaSetup, ServiceCard } from '../shared/types.js';

export type HomepageConfig = {
  domain: string;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  offlineMedia?: OfflineMediaSetup;
  offlineMusic?: OfflineMediaSetup;
};

export type AppConfig = {
  host: string;
  port: number;
  staticDir: string;
  devUser?: string;
  sftpKeyInstallCommand?: string;
  syncthingDeviceIdCommand?: string;
  offlineMediaStatusCommand?: string;
  offlineMediaEnrollCommand?: string;
  offlineMediaRemoveCommand?: string;
  sudoPath: string;
  homepage: HomepageConfig;
};

const numberFromEnv = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

const fallbackHomepage: HomepageConfig = {
  domain: 'example.test',
  services: [],
  folderGuides: [],
  adminGuide: [],
  kanidmGroups: [],
  offlineMedia: undefined,
  offlineMusic: undefined,
};

export const loadHomepageConfig = (path: string | undefined): HomepageConfig => {
  if (!path) {
    return fallbackHomepage;
  }
  return JSON.parse(readFileSync(path, 'utf8')) as HomepageConfig;
};

export const loadConfig = (): AppConfig => ({
  host: process.env.HOMEPAGE_HOST ?? '127.0.0.1',
  port: numberFromEnv('HOMEPAGE_PORT', 8084),
  staticDir: process.env.HOMEPAGE_STATIC_DIR ?? new URL('../../client', import.meta.url).pathname,
  devUser: process.env.HOMEPAGE_DEV_USER,
  sftpKeyInstallCommand: process.env.HOMEPAGE_SFTP_KEY_INSTALL_COMMAND,
  syncthingDeviceIdCommand: process.env.HOMEPAGE_SYNCTHING_DEVICE_ID_COMMAND,
  offlineMediaStatusCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_STATUS_COMMAND ?? process.env.HOMEPAGE_OFFLINE_MUSIC_STATUS_COMMAND,
  offlineMediaEnrollCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND ?? process.env.HOMEPAGE_OFFLINE_MUSIC_ENROLL_COMMAND,
  offlineMediaRemoveCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_REMOVE_COMMAND,
  sudoPath: process.env.HOMEPAGE_SUDO ?? 'sudo',
  homepage: loadHomepageConfig(process.env.HOMEPAGE_CONFIG_FILE),
});
