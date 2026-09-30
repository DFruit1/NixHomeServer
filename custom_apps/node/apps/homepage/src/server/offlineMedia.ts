import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { AppConfig } from './config.js';
import { getSyncthingDeviceId } from './syncthing.js';
import type {
  CurrentUser,
  OfflineMediaEnrollResponse,
  OfflineMediaRemoveResponse,
  OfflineMediaSetup,
} from '../shared/types.js';

const DEVICE_ID_PATTERN = /^[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}$/;
const DEVICE_NAME_PATTERN = /^[A-Za-z0-9._ -]{1,64}$/;

export class OfflineMediaInputError extends Error {
  override readonly name = 'OfflineMediaInputError';
}

export type OfflineMediaEnrollInput = {
  deviceId?: unknown;
  deviceName?: unknown;
};

export const normaliseSyncthingDeviceId = (raw: unknown): string => {
  if (typeof raw !== 'string') {
    throw new OfflineMediaInputError('deviceId must be a string');
  }
  const deviceId = raw.trim().toUpperCase();
  if (!DEVICE_ID_PATTERN.test(deviceId)) {
    throw new OfflineMediaInputError('deviceId must be a valid Syncthing device ID');
  }
  return deviceId;
};

export const normaliseSyncthingDeviceName = (raw: unknown, username: string): string => {
  if (raw === undefined || raw === null || raw === '') {
    return `${username}-media`;
  }
  if (typeof raw !== 'string') {
    throw new OfflineMediaInputError('deviceName must be a string');
  }
  const deviceName = raw.trim();
  if (!DEVICE_NAME_PATTERN.test(deviceName)) {
    throw new OfflineMediaInputError('deviceName must be 1-64 printable characters');
  }
  return deviceName;
};

const offlineMediaConfig = (config: AppConfig): OfflineMediaSetup | undefined =>
  config.homepage.offlineMedia;

// The status helper spawns sudo plus a shell probe (pings, per-device/per-folder
// curl fan-out) and runs on every SSR render and every 15s client poll. Share
// one in-flight result per user across the route loader and the API endpoint so
// concurrent renders/polls coalesce into a single helper run. TTL sits just
// above the client poll interval; enrollment/removal invalidate eagerly so the
// next poll never resurrects pre-mutation device lists. Failures are not
// retained, so a transient helper error recovers on the next call.
const SETUP_TTL_MS = 20_000;
const setupCache = new Map<string, { promise: Promise<OfflineMediaSetup>; expiresAt: number }>();

const setupCacheKey = (config: AppConfig, user: CurrentUser, base: OfflineMediaSetup): string =>
  JSON.stringify([
    config.sudoPath,
    config.syncthingDeviceIdCommand,
    config.offlineMediaStatusCommand,
    user.username,
    base,
  ]);

const invalidateSetupCache = (config: AppConfig, user: CurrentUser): void => {
  const base = offlineMediaConfig(config);
  if (base?.enabled) {
    setupCache.delete(setupCacheKey(config, user, base));
  }
};

const resolveOfflineMediaSetup = async (config: AppConfig, user: CurrentUser, base: OfflineMediaSetup): Promise<OfflineMediaSetup> => {
  let setup: OfflineMediaSetup = { ...base, folders: base.folders ?? [], devices: base.devices ?? [] };
  if (config.syncthingDeviceIdCommand) {
    setup.serverDeviceId = await getSyncthingDeviceId(config);
  }
  if (config.offlineMediaStatusCommand) {
    const runtimeSetup = await runJsonHelper<Partial<OfflineMediaSetup>>(
      config,
      config.offlineMediaStatusCommand,
      [user.username],
    );
    setup = {
      ...setup,
      ...runtimeSetup,
      // Connection routes and their meanings are declarative network data.
      // A runtime status helper must not replace them with stale or malformed
      // values while reporting devices and folders.
      connectionAddresses: base.connectionAddresses,
    };
  }
  return setup;
};

export const getOfflineMediaSetup = async (config: AppConfig, user: CurrentUser): Promise<OfflineMediaSetup | undefined> => {
  const base = offlineMediaConfig(config);
  if (!base?.enabled) {
    return base;
  }

  const key = setupCacheKey(config, user, base);
  const cached = setupCache.get(key);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.promise;
  }

  const entry = {
    promise: resolveOfflineMediaSetup(config, user, base),
    expiresAt: Date.now() + SETUP_TTL_MS,
  };
  setupCache.set(key, entry);
  void entry.promise.catch(() => {
    if (setupCache.get(key) === entry) {
      setupCache.delete(key);
    }
  });
  return entry.promise;
};

export const enrollOfflineMediaDevice = async (
  config: AppConfig,
  user: CurrentUser,
  input: OfflineMediaEnrollInput,
): Promise<OfflineMediaEnrollResponse> => {
  if (!offlineMediaConfig(config)?.enabled) {
    throw new Error('offline media sync is not enabled');
  }
  if (!config.offlineMediaEnrollCommand) {
    throw new Error('offline media enrollment is not configured');
  }

  const payload = {
    deviceId: normaliseSyncthingDeviceId(input.deviceId),
    deviceName: normaliseSyncthingDeviceName(input.deviceName, user.username),
  };
  const response = await runJsonHelper<OfflineMediaEnrollResponse>(config, config.offlineMediaEnrollCommand, [user.username], payload);
  invalidateSetupCache(config, user);
  return response;
};

export const removeOfflineMediaDevice = async (
  config: AppConfig,
  user: CurrentUser,
  rawDeviceId: unknown,
): Promise<OfflineMediaRemoveResponse> => {
  if (!offlineMediaConfig(config)?.enabled) {
    throw new Error('offline media sync is not enabled');
  }
  if (!config.offlineMediaRemoveCommand) {
    throw new Error('offline media device removal is not configured');
  }

  const deviceId = normaliseSyncthingDeviceId(rawDeviceId);
  const response = await runJsonHelper<OfflineMediaRemoveResponse>(config, config.offlineMediaRemoveCommand, [user.username, deviceId]);
  invalidateSetupCache(config, user);
  return response;
};

const runJsonHelper = <T>(config: AppConfig, command: string, args: string[], input?: unknown): Promise<T> =>
  new Promise((resolve, reject) => {
    const child = spawn(config.sudoPath, ['-n', command, ...args], {
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      const output = Buffer.concat(stdout).toString('utf8').trim();
      if (code === 0) {
        try {
          resolve((output ? JSON.parse(output) : {}) as T);
        } catch (error) {
          reject(new Error(`offline media helper returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`));
        }
        return;
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `offline media helper exited with status ${code}`));
    });

    if (input === undefined) {
      child.stdin.end();
    } else {
      child.stdin.end(`${JSON.stringify(input)}\n`);
    }
  });
