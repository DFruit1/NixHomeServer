import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { AppConfig } from './config.js';
import { getSyncthingDeviceId } from './syncthing.js';
import type { CurrentUser, OfflineMusicEnrollResponse, OfflineMusicSetup } from '../shared/types.js';

const DEVICE_ID_PATTERN = /^[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}$/;
const DEVICE_NAME_PATTERN = /^[A-Za-z0-9._ -]{1,64}$/;

export type OfflineMusicEnrollInput = {
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
    return `${username}-music`;
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

export const getOfflineMusicSetup = async (config: AppConfig, user: CurrentUser): Promise<OfflineMusicSetup | undefined> => {
  const base = config.homepage.offlineMusic;
  if (!base?.enabled) {
    return base;
  }

  let setup: OfflineMusicSetup = { ...base };
  if (config.syncthingDeviceIdCommand) {
    setup.serverDeviceId = await getSyncthingDeviceId(config);
  }
  if (config.offlineMusicStatusCommand) {
    setup = {
      ...setup,
      ...(await runJsonHelper<Partial<OfflineMusicSetup>>(config, config.offlineMusicStatusCommand, [user.username])),
    };
  }
  return setup;
};

export const enrollOfflineMusicDevice = async (
  config: AppConfig,
  user: CurrentUser,
  input: OfflineMusicEnrollInput,
): Promise<OfflineMusicEnrollResponse> => {
  if (!config.homepage.offlineMusic?.enabled) {
    throw new Error('offline music sync is not enabled');
  }
  if (!config.offlineMusicEnrollCommand) {
    throw new Error('offline music enrollment is not configured');
  }

  const payload = {
    deviceId: normaliseSyncthingDeviceId(input.deviceId),
    deviceName: normaliseSyncthingDeviceName(input.deviceName, user.username),
  };
  return runJsonHelper<OfflineMusicEnrollResponse>(config, config.offlineMusicEnrollCommand, [user.username], payload);
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
          reject(new Error(`offline music helper returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`));
        }
        return;
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `offline music helper exited with status ${code}`));
    });

    if (input === undefined) {
      child.stdin.end();
    } else {
      child.stdin.end(`${JSON.stringify(input)}\n`);
    }
  });
