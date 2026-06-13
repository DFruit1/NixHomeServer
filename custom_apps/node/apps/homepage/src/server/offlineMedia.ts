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

export type OfflineMediaEnrollInput = {
  deviceId?: unknown;
  deviceName?: unknown;
};

export const normaliseSyncthingDeviceId = (raw: unknown): string => {
  if (typeof raw !== 'string') {
    throw new Error('deviceId must be a string');
  }
  const deviceId = raw.trim().toUpperCase();
  if (!DEVICE_ID_PATTERN.test(deviceId)) {
    throw new Error('deviceId must be a valid Syncthing device ID');
  }
  return deviceId;
};

export const normaliseSyncthingDeviceName = (raw: unknown, username: string): string => {
  if (raw === undefined || raw === null || raw === '') {
    return `${username}-media`;
  }
  if (typeof raw !== 'string') {
    throw new Error('deviceName must be a string');
  }
  const deviceName = raw.trim();
  if (!DEVICE_NAME_PATTERN.test(deviceName)) {
    throw new Error('deviceName must be 1-64 printable characters');
  }
  return deviceName;
};

const offlineMediaConfig = (config: AppConfig): OfflineMediaSetup | undefined =>
  config.homepage.offlineMedia ?? config.homepage.offlineMusic;

export const getOfflineMediaSetup = async (config: AppConfig, user: CurrentUser): Promise<OfflineMediaSetup | undefined> => {
  const base = offlineMediaConfig(config);
  if (!base?.enabled) {
    return base;
  }

  let setup: OfflineMediaSetup = { ...base, folders: base.folders ?? [], devices: base.devices ?? [] };
  if (config.syncthingDeviceIdCommand) {
    setup.serverDeviceId = await getSyncthingDeviceId(config);
  }
  if (config.offlineMediaStatusCommand) {
    setup = {
      ...setup,
      ...(await runJsonHelper<Partial<OfflineMediaSetup>>(config, config.offlineMediaStatusCommand, [user.username])),
    };
  }
  return setup;
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
  return runJsonHelper<OfflineMediaEnrollResponse>(config, config.offlineMediaEnrollCommand, [user.username], payload);
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
  return runJsonHelper<OfflineMediaRemoveResponse>(config, config.offlineMediaRemoveCommand, [user.username, deviceId]);
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
