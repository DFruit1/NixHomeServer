import { spawn } from 'node:child_process';
import type { AppConfig } from './config.js';

const DEVICE_ID_PATTERN = /^[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}$/;

// The device ID derives from Syncthing's keypair and cannot change while this
// process runs, so a successful lookup is kept for the process lifetime
// instead of spawning sudo on every render. A failed lookup is not retained:
// the next render retries and surfaces the error again.
const deviceIdCache = new Map<string, Promise<string>>();

export const getSyncthingDeviceId = async (config: AppConfig): Promise<string | undefined> => {
  if (!config.syncthingDeviceIdCommand) {
    return undefined;
  }

  const key = JSON.stringify([config.sudoPath, config.syncthingDeviceIdCommand]);
  let pending = deviceIdCache.get(key);
  if (!pending) {
    pending = runDeviceIdCommand(config).then((output) => {
      const deviceId = output.trim();
      if (!DEVICE_ID_PATTERN.test(deviceId)) {
        throw new Error('Syncthing device ID command returned an invalid device ID');
      }
      return deviceId;
    });
    deviceIdCache.set(key, pending);
    const stored = pending;
    void stored.catch(() => {
      if (deviceIdCache.get(key) === stored) {
        deviceIdCache.delete(key);
      }
    });
  }
  return pending;
};

const runDeviceIdCommand = (config: AppConfig): Promise<string> =>
  new Promise((resolve, reject) => {
    const child = spawn(config.sudoPath, ['-n', config.syncthingDeviceIdCommand ?? ''], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString('utf8'));
        return;
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `Syncthing device ID command exited with status ${code}`));
    });
  });
