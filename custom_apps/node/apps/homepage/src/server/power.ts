import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { isHomepageAdmin } from './homepageData.js';
import type { PowerSchedule, PowerScheduleResponse, PowerScheduleValues } from '../shared/types.js';

const WAKE_TIME_PATTERN = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
const UPDATED_AT_MAX_LENGTH = 40;
const SKIP_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export class PowerScheduleInputError extends Error {
  override readonly name = 'PowerScheduleInputError';
}

const requirePowerAdmin = (config: AppConfig, headers: IncomingHttpHeaders): void => {
  const user = currentUserFromHeaders(headers, config.devUser);
  if (!isHomepageAdmin(config, user)) {
    throw new Error('not authorised to manage the power schedule');
  }
};

export const normalisePowerScheduleValues = (input: unknown): PowerScheduleValues => {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) {
    throw new PowerScheduleInputError('power schedule payload must be an object');
  }
  const raw = input as Record<string, unknown>;
  if (typeof raw.enabled !== 'boolean') {
    throw new PowerScheduleInputError('enabled must be a boolean');
  }
  if (typeof raw.wakeTime !== 'string' || !WAKE_TIME_PATTERN.test(raw.wakeTime)) {
    throw new PowerScheduleInputError('wakeTime must be an HH:MM time between 00:00 and 23:59');
  }
  const hour = (label: string, candidate: unknown): number => {
    if (typeof candidate !== 'number' || !Number.isInteger(candidate) || candidate < 0 || candidate > 23) {
      throw new PowerScheduleInputError(`${label} must be a whole hour between 0 and 23`);
    }
    return candidate;
  };
  const idleWindowStartHour = hour('idleWindowStartHour', raw.idleWindowStartHour);
  const forcedWindowEndHour = hour('forcedWindowEndHour', raw.forcedWindowEndHour);
  if (forcedWindowEndHour > idleWindowStartHour) {
    throw new PowerScheduleInputError('forcedWindowEndHour must not be later than idleWindowStartHour');
  }
  const wakeMinutes = Number(raw.wakeTime.slice(0, 2)) * 60 + Number(raw.wakeTime.slice(3));
  if (wakeMinutes < forcedWindowEndHour * 60) {
    throw new PowerScheduleInputError('wakeTime must not fall before the end of the forced-suspend window');
  }
  return {
    enabled: raw.enabled,
    wakeTime: raw.wakeTime,
    idleWindowStartHour,
    forcedWindowEndHour,
  };
};

const normaliseUpdatedAt = (value: unknown): string | undefined =>
  typeof value === 'string' && value.length > 0 && value.length <= UPDATED_AT_MAX_LENGTH
    ? value
    : undefined;

const normaliseSkipDate = (value: unknown): string | null | undefined => {
  if (value === null || value === undefined || value === '') return undefined;
  return typeof value === 'string' && SKIP_DATE_PATTERN.test(value) ? value : undefined;
};

const parseStoredSchedule = (text: string): PowerSchedule => {
  const raw = JSON.parse(text) as unknown;
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new Error('stored power schedule must be an object');
  }
  const value = raw as Record<string, unknown>;
  if (value.schemaVersion !== 1) {
    throw new Error('unsupported power schedule schemaVersion');
  }
  return {
    schemaVersion: 1,
    ...normalisePowerScheduleValues(value),
    ...(normaliseSkipDate(value.skipDate) ? { skipDate: normaliseSkipDate(value.skipDate) } : {}),
    updatedAt: normaliseUpdatedAt(value.updatedAt),
  };
};

const readStoredSchedule = async (stateFile: string, defaults: PowerScheduleValues): Promise<{
  current: PowerSchedule;
  warning?: string;
}> => {
  let text: string;
  try {
    text = await readFile(stateFile, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return { current: { schemaVersion: 1, ...defaults } };
    }
    throw error;
  }
  try {
    return { current: parseStoredSchedule(text) };
  } catch (error) {
    return {
      current: { schemaVersion: 1, ...defaults },
      warning: `the stored power schedule is invalid and the Nix defaults are in effect (${error instanceof Error ? error.message : String(error)})`,
    };
  }
};

const requireFeature = (config: AppConfig): NonNullable<AppConfig['powerSchedule']> => {
  if (!config.powerSchedule) {
    throw new Error('the power schedule is not enabled on this server');
  }
  return config.powerSchedule;
};

export const getPowerSchedule = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<PowerScheduleResponse> => {
  requirePowerAdmin(config, headers);
  const feature = requireFeature(config);
  const stored = await readStoredSchedule(feature.stateFile, feature.defaults);
  return {
    available: true,
    current: stored.current,
    defaults: feature.defaults,
    warning: stored.warning,
  };
};

const runApplyHelper = (command: string, sudoPath: string, payload: PowerScheduleValues & { skipDate?: string | null }): Promise<PowerSchedule> =>
  new Promise((resolve, reject) => {
    const child = spawn(sudoPath, ['-n', command], {
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', (error) => {
      reject(new Error(`power schedule helper exited before starting: ${error instanceof Error ? error.message : String(error)}`));
    });
    child.on('close', (code) => {
      const output = Buffer.concat(stdout).toString('utf8').trim();
      if (code === 0) {
        try {
          resolve(parseStoredSchedule(output));
          return;
        } catch (error) {
          reject(new Error(`power schedule helper returned an invalid schedule: ${error instanceof Error ? error.message : String(error)}`));
          return;
        }
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `power schedule helper exited with status ${code}`));
    });

    child.stdin.end(`${JSON.stringify(payload)}\n`);
  });

export const applyPowerSchedule = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  input: unknown,
): Promise<PowerScheduleResponse> => {
  requirePowerAdmin(config, headers);
  const feature = requireFeature(config);
  if (!feature.applyCommand) {
    throw new Error('power schedule updates are not enabled on this server');
  }
  const values = normalisePowerScheduleValues(input);
  const rawSkipDate = (input as Record<string, unknown>).skipDate;
  if (rawSkipDate !== undefined && rawSkipDate !== null && rawSkipDate !== '' && !normaliseSkipDate(rawSkipDate)) {
    throw new PowerScheduleInputError('skipDate must be an ISO calendar date');
  }
  const current = await runApplyHelper(feature.applyCommand, config.sudoPath, {
    ...values,
    ...(rawSkipDate !== undefined ? { skipDate: rawSkipDate as string | null } : {}),
  });
  return {
    available: true,
    current,
    defaults: feature.defaults,
  };
};
