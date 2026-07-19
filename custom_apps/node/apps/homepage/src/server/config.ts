import { readFileSync } from 'node:fs';
import { fallbackBrandName } from '../shared/branding.js';
import type { AdminStep, FolderGuide, OfflineMediaSetup, ServiceCard } from '../shared/types.js';

export type HomepageConfig = {
  brandName: string;
  domain: string;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  kanidmGroupDescriptions?: Record<string, string>;
  offlineMedia?: OfflineMediaSetup;
  canaryAdminUser?: string;
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
  canaryAdminUser?: string;
  canaryStateDir?: string;
  canaryTriggerCommand?: string;
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
  brandName: fallbackBrandName,
  domain: 'example.test',
  services: [],
  folderGuides: [],
  adminGuide: [],
  kanidmGroups: [],
  kanidmGroupDescriptions: {},
  offlineMedia: undefined,
  canaryAdminUser: undefined,
};

export const loadHomepageConfig = (path: string | undefined): HomepageConfig => {
  if (!path) {
    return fallbackHomepage;
  }
  const parsed = JSON.parse(readFileSync(path, 'utf8')) as Partial<HomepageConfig>;
  const brandName = typeof parsed.brandName === 'string' ? parsed.brandName.trim() : '';
  if (!brandName || brandName.length > 100) {
    throw new Error('homepage brandName must be a non-empty string of at most 100 characters');
  }
  const domain = typeof parsed.domain === 'string' ? parsed.domain.trim() : '';
  if (!domain) {
    throw new Error('homepage domain must be a non-empty string');
  }
  return {
    ...(parsed as HomepageConfig),
    brandName,
    domain,
  };
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
  canaryAdminUser: process.env.HOMEPAGE_CANARY_ADMIN_USER,
  canaryStateDir: process.env.HOMEPAGE_CANARY_STATE_DIR,
  canaryTriggerCommand: process.env.HOMEPAGE_CANARY_TRIGGER_COMMAND,
  homepage: loadHomepageConfig(process.env.HOMEPAGE_CONFIG_FILE),
});
