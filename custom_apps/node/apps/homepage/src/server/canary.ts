import { execFile } from 'node:child_process';
import { readdir, readFile } from 'node:fs/promises';
import { promisify } from 'node:util';
import type { IncomingHttpHeaders } from 'node:http';
import { join } from 'node:path';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import type { CanaryRunSummary, CanaryStatusResponse } from '../shared/types.js';

const execFileAsync = promisify(execFile);
const runIdPattern = /^[A-Za-z0-9._-]{1,160}$/;

const requireAdmin = (config: AppConfig, headers: IncomingHttpHeaders): void => {
  const user = currentUserFromHeaders(headers, config.devUser);
  if (!config.canaryAdminUser || user.username !== config.canaryAdminUser) {
    throw new Error('not authorised to manage the service-access canary');
  }
};

const parseRun = (text: string): CanaryRunSummary => {
  const value = JSON.parse(text) as Partial<CanaryRunSummary>;
  if (value.schemaVersion !== 1 || typeof value.state !== 'string') {
    throw new Error('invalid canary result schema');
  }
  return value as CanaryRunSummary;
};

const readRun = async (path: string): Promise<CanaryRunSummary | undefined> => {
  try {
    return parseRun(await readFile(path, 'utf8'));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw error;
  }
};

const stateDir = (config: AppConfig): string => {
  if (!config.canaryStateDir) throw new Error('canary state directory is not configured');
  return config.canaryStateDir;
};

export const getCanaryStatus = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<CanaryStatusResponse> => {
  requireAdmin(config, headers);
  const directory = stateDir(config);
  const [running, latest, entries] = await Promise.all([
    readRun(join(directory, 'running.json')),
    readRun(join(directory, 'latest.json')),
    readdir(join(directory, 'failures')).catch((error: NodeJS.ErrnoException) => error.code === 'ENOENT' ? [] : Promise.reject(error)),
  ]);
  const retainedFailures = (await Promise.all(
    entries
      .filter((entry) => entry.endsWith('.json') && runIdPattern.test(entry.slice(0, -5)))
      .sort()
      .reverse()
      .map((entry) => readRun(join(directory, 'failures', entry))),
  )).filter((run): run is CanaryRunSummary => Boolean(run));
  return {
    current: running ?? latest ?? { schemaVersion: 1, state: 'never-run' },
    retainedFailures,
  };
};

export const getCanaryFailure = async (config: AppConfig, headers: IncomingHttpHeaders, runId: string): Promise<CanaryRunSummary> => {
  requireAdmin(config, headers);
  if (!runIdPattern.test(runId)) throw new Error('invalid canary run id');
  const run = await readRun(join(stateDir(config), 'failures', `${runId}.json`));
  if (!run) throw new Error('canary failure record not found');
  return run;
};

export const triggerCanary = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<{ accepted: true }> => {
  requireAdmin(config, headers);
  if (!config.canaryTriggerCommand) throw new Error('canary trigger is not configured');
  try {
    await execFileAsync(config.sudoPath, ['-n', config.canaryTriggerCommand], { timeout: 10_000 });
  } catch (error) {
    const failure = error as NodeJS.ErrnoException & { code?: number; stderr?: string };
    if (failure.code === 75 || failure.stderr?.includes('already active')) throw new Error('canary run already active');
    throw new Error(`unable to start canary: ${failure.stderr?.trim() || failure.message}`);
  }
  return { accepted: true };
};
