import type {
  AdminStep,
  FolderGuide,
  KanidmGroupManagementSource,
  OfflineMediaConnectionAddress,
  OfflineMediaSetup,
  PowerScheduleValues,
  ServiceCard,
  VaultConfig,
  VaultFeatureGate,
} from '../shared/types.js';
import { readFileSync } from 'node:fs';
import { numberFromEnv } from '../shared/node-common/env.js';
import { fallbackBrandName } from '../shared/branding.js';

export type HomepageConfig = {
  brandName: string;
  domain: string;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  kanidmGroupDescriptions?: Record<string, string>;
  kanidmGroupManagement?: Record<string, KanidmGroupManagementSource>;
  adminUsers?: string[];
  adminGroups?: string[];
  sftp?: {
    enabled: boolean;
    host: string;
    port: number;
    networkNote: string;
    requiredAllGroups?: string[];
    requiredAnyGroups?: string[];
    accessNotes?: Array<{
      text: string;
      requiredAllGroups?: string[];
      requiredAnyGroups?: string[];
    }>;
  };
  offlineMedia?: OfflineMediaSetup;
  canaryAdminUser?: string;
  vault?: VaultConfig;
};

export type AppConfig = {
  host: string;
  port: number;
  staticDir: string;
  devUser?: string;
  sftpKeyInstallCommand?: string;
  sftpKeyListCommand?: string;
  syncthingDeviceIdCommand?: string;
  offlineMediaStatusCommand?: string;
  offlineMediaEnrollCommand?: string;
  offlineMediaRemoveCommand?: string;
  vaultKanidmUrl?: string;
  vaultSyncthingKeyCommand?: string;
  vaultFreshrssPasswordCommand?: string;
  vaultKavitaKeysCommand?: string;
  sudoPath: string;
  canaryAdminUser?: string;
  canaryStateDir?: string;
  canaryTriggerCommand?: string;
  mkvmakerProgressFile?: string;
  powerSchedule?: {
    available: true;
    stateFile: string;
    applyCommand?: string;
    defaults: PowerScheduleValues;
  };
  buildMode?: {
    available: true;
    stateFile: string;
    applyCommand?: string;
    defaultMode: string;
  };
  homepage: HomepageConfig;
};

const fallbackHomepage: HomepageConfig = {
  brandName: fallbackBrandName,
  domain: 'example.test',
  services: [],
  folderGuides: [],
  adminGuide: [],
  kanidmGroups: [],
  kanidmGroupDescriptions: {},
  kanidmGroupManagement: {},
  adminUsers: [],
  adminGroups: [],
  offlineMedia: undefined,
  canaryAdminUser: undefined,
};

const singleLineString = (value: unknown, maximumLength: number): string | undefined => {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maximumLength || /[\u0000-\u001f\u007f]/.test(trimmed)) {
    return undefined;
  }
  return trimmed;
};

export const normaliseOfflineMediaConnectionAddresses = (value: unknown): OfflineMediaConnectionAddress[] => {
  if (!Array.isArray(value)) {
    return [];
  }

  const connections: OfflineMediaConnectionAddress[] = [];
  const seenAddresses = new Set<string>();
  for (const entry of value) {
    const legacyAddress = singleLineString(entry, 512);
    const objectEntry = typeof entry === 'object' && entry !== null && !Array.isArray(entry)
      ? entry as Record<string, unknown>
      : undefined;
    const address = legacyAddress ?? singleLineString(objectEntry?.address, 512);
    if (!address || seenAddresses.has(address)) {
      continue;
    }
    const label = legacyAddress
      ? 'Server address'
      : singleLineString(objectEntry?.label, 100) ?? 'Server address';
    seenAddresses.add(address);
    connections.push({ address, label });
  }
  return connections;
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
  const offlineMediaRaw = parsed.offlineMedia;
  const offlineMedia = typeof offlineMediaRaw === 'object' && offlineMediaRaw !== null && !Array.isArray(offlineMediaRaw)
    ? {
        ...(offlineMediaRaw as OfflineMediaSetup),
        connectionAddresses: normaliseOfflineMediaConnectionAddresses(
          (offlineMediaRaw as { connectionAddresses?: unknown }).connectionAddresses,
        ),
      }
    : undefined;
  return {
    ...(parsed as HomepageConfig),
    brandName,
    domain,
    offlineMedia,
    vault: normaliseVaultConfig(parsed.vault),
  };
};

const clampPositiveInteger = (value: unknown, fallback: number, minimum: number, maximum: number): number => {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  const rounded = Math.floor(value);
  if (rounded < minimum) {
    return minimum;
  }
  if (rounded > maximum) {
    return maximum;
  }
  return rounded;
};

const normaliseGroupList = (value: unknown): string[] | undefined => {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const groups = value.filter((group): group is string => typeof group === 'string' && group.trim().length > 0);
  return groups.length > 0 ? [...new Set(groups)] : undefined;
};

const loopbackHosts = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

const normaliseKanidmUrl = (value: string | undefined): string | undefined => {
  if (!value) {
    return undefined;
  }
  let parsed: URL;
  try {
    parsed = new URL(value.trim());
  } catch {
    return undefined;
  }
  const isLoopback = loopbackHosts.has(parsed.hostname) || loopbackHosts.has(parsed.hostname.toLowerCase());
  if (parsed.protocol === 'https:' || (parsed.protocol === 'http:' && isLoopback)) {
    if (!parsed.host || (parsed.pathname !== '/' && parsed.pathname !== '') || parsed.search || parsed.username || parsed.password) {
      return undefined;
    }
    return parsed.origin === `${parsed.protocol}//${parsed.host}` ? value.trim().replace(/\/$/, '') : parsed.origin;
  }
  return undefined;
};

const normaliseVaultFeatureGate = (value: unknown): VaultFeatureGate | undefined => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return undefined;
  }
  const gate = value as Record<string, unknown>;
  return {
    enabled: gate.enabled === true,
    requiredAllGroups: normaliseGroupList(gate.requiredAllGroups),
    requiredAnyGroups: normaliseGroupList(gate.requiredAnyGroups),
  };
};

export const normaliseVaultConfig = (value: unknown): VaultConfig | undefined => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return undefined;
  }
  const vault = value as Record<string, unknown>;
  const kanidmBaseUrl = singleLineString(vault.kanidmBaseUrl, 256);
  if (!vault.enabled || !kanidmBaseUrl || !/^https:\/\//.test(kanidmBaseUrl)) {
    return undefined;
  }
  const featuresRaw = typeof vault.features === 'object' && vault.features !== null && !Array.isArray(vault.features)
    ? (vault.features as Record<string, unknown>)
    : {};
  const syncthingRaw = typeof featuresRaw.syncthingApiKey === 'object' && featuresRaw.syncthingApiKey !== null && !Array.isArray(featuresRaw.syncthingApiKey)
    ? (featuresRaw.syncthingApiKey as Record<string, unknown>)
    : undefined;
  const syncthingGate = normaliseVaultFeatureGate(featuresRaw.syncthingApiKey);
  const freshrssGate = normaliseVaultFeatureGate(featuresRaw.freshrssApiPassword);
  const kavitaGate = normaliseVaultFeatureGate(featuresRaw.kavitaApiKeys);
  const sshGate = normaliseVaultFeatureGate(featuresRaw.sshKeys);
  const sessionTtlSeconds = clampPositiveInteger(vault.sessionTtlSeconds, 900, 120, 3600);
  const idleTtlSeconds = clampPositiveInteger(vault.idleTtlSeconds, 300, 60, Math.min(1800, sessionTtlSeconds));
  return {
    enabled: true,
    kanidmBaseUrl,
    sessionTtlSeconds,
    idleTtlSeconds,
    freshrssWebUrl: singleLineString(vault.freshrssWebUrl, 256),
    kavitaWebUrl: singleLineString(vault.kavitaWebUrl, 256),
    features: {
      sshKeys: sshGate,
      syncthingApiKey: syncthingGate
        ? { ...syncthingGate, adminOnly: syncthingRaw?.adminOnly !== false }
        : undefined,
      freshrssApiPassword: freshrssGate,
      kavitaApiKeys: kavitaGate,
    },
  };
};

const normalisePowerScheduleDefaults = (value: unknown): PowerScheduleValues | undefined => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return undefined;
  }
  const raw = value as Record<string, unknown>;
  const hour = (candidate: unknown): candidate is number =>
    typeof candidate === 'number' && Number.isInteger(candidate) && candidate >= 0 && candidate <= 23;
  if (typeof raw.enabled !== 'boolean') {
    return undefined;
  }
  if (typeof raw.wakeTime !== 'string' || !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(raw.wakeTime)) {
    return undefined;
  }
  if (!hour(raw.idleWindowStartHour) || !hour(raw.forcedWindowEndHour) || raw.forcedWindowEndHour > raw.idleWindowStartHour) {
    return undefined;
  }
  return {
    enabled: raw.enabled,
    wakeTime: raw.wakeTime,
    idleWindowStartHour: raw.idleWindowStartHour,
    forcedWindowEndHour: raw.forcedWindowEndHour,
  };
};

const normalisePowerScheduleConfig = (): AppConfig['powerSchedule'] | undefined => {
  const stateFile = process.env.HOMEPAGE_POWER_SCHEDULE_FILE;
  const defaults = safeJsonParse(process.env.HOMEPAGE_POWER_SCHEDULE_DEFAULTS);
  if (!stateFile || !defaults) {
    return undefined;
  }
  const normalisedDefaults = normalisePowerScheduleDefaults(defaults);
  if (!normalisedDefaults) {
    return undefined;
  }
  return {
    available: true,
    stateFile,
    applyCommand: process.env.HOMEPAGE_POWER_SCHEDULE_APPLY_COMMAND,
    defaults: normalisedDefaults,
  };
};

const safeJsonParse = (raw: string | undefined): unknown => {
  if (!raw) {
    return undefined;
  }
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    return undefined;
  }
};

const normaliseBuildModeConfig = (): AppConfig['buildMode'] | undefined => {
  const stateFile = process.env.HOMEPAGE_BUILD_MODE_FILE;
  const defaultMode = process.env.HOMEPAGE_BUILD_MODE_DEFAULT;
  if (!stateFile || !defaultMode || !['local', 'remote', 'balanced', 'maximum-effort'].includes(defaultMode)) {
    return undefined;
  }
  return {
    available: true,
    stateFile,
    applyCommand: process.env.HOMEPAGE_BUILD_MODE_APPLY_COMMAND,
    defaultMode,
  };
};

export const loadConfig = (): AppConfig => ({
  host: process.env.HOMEPAGE_HOST ?? '127.0.0.1',
  port: numberFromEnv('HOMEPAGE_PORT', 8084),
  staticDir: process.env.HOMEPAGE_STATIC_DIR ?? new URL('../../client', import.meta.url).pathname,
  devUser: process.env.HOMEPAGE_DEV_USER,
  sftpKeyInstallCommand: process.env.HOMEPAGE_SFTP_KEY_INSTALL_COMMAND,
  sftpKeyListCommand: process.env.HOMEPAGE_SFTP_KEY_LIST_COMMAND,
  syncthingDeviceIdCommand: process.env.HOMEPAGE_SYNCTHING_DEVICE_ID_COMMAND,
  offlineMediaStatusCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_STATUS_COMMAND ?? process.env.HOMEPAGE_OFFLINE_MUSIC_STATUS_COMMAND,
  offlineMediaEnrollCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND ?? process.env.HOMEPAGE_OFFLINE_MUSIC_ENROLL_COMMAND,
  offlineMediaRemoveCommand: process.env.HOMEPAGE_OFFLINE_MEDIA_REMOVE_COMMAND,
  vaultKanidmUrl: normaliseKanidmUrl(process.env.HOMEPAGE_VAULT_KANIDM_URL),
  vaultSyncthingKeyCommand: process.env.HOMEPAGE_VAULT_SYNCTHING_KEY_COMMAND,
  vaultFreshrssPasswordCommand: process.env.HOMEPAGE_VAULT_FRESHRSS_PASSWORD_COMMAND,
  vaultKavitaKeysCommand: process.env.HOMEPAGE_VAULT_KAVITA_KEYS_COMMAND,
  sudoPath: process.env.HOMEPAGE_SUDO ?? 'sudo',
  canaryAdminUser: process.env.HOMEPAGE_CANARY_ADMIN_USER,
  canaryStateDir: process.env.HOMEPAGE_CANARY_STATE_DIR,
  canaryTriggerCommand: process.env.HOMEPAGE_CANARY_TRIGGER_COMMAND,
  mkvmakerProgressFile: process.env.HOMEPAGE_MKVMAKER_PROGRESS_FILE,
  powerSchedule: normalisePowerScheduleConfig(),
  buildMode: normaliseBuildModeConfig(),
  homepage: loadHomepageConfig(process.env.HOMEPAGE_CONFIG_FILE),
});
