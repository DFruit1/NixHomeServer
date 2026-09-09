import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { isHomepageAdmin } from './homepageData.js';
import type { BuildMode, BuildModeResponse } from '../shared/types.js';

const BUILD_MODES: readonly BuildMode[] = ['local', 'remote', 'balanced', 'maximum-effort'];
const BUILD_MODE_DESCRIPTIONS: Record<BuildMode, string> = {
  local: 'Build entirely on this workstation; copy the closure to the server.',
  remote: 'Build entirely on the server.',
  balanced: 'Two slots on each machine, one requested core per job.',
  'maximum-effort': 'All available slots on both machines.',
};
const UPDATED_AT_MAX_LENGTH = 40;

export class BuildModeInputError extends Error {
  override readonly name = 'BuildModeInputError';
}

const requireBuildModeAdmin = (config: AppConfig, headers: IncomingHttpHeaders): void => {
  const user = currentUserFromHeaders(headers, config.devUser);
  if (!isHomepageAdmin(config, user)) {
    throw new Error('not authorised to manage the Nix build mode');
  }
};

const isBuildMode = (value: unknown): value is BuildMode =>
  typeof value === 'string' && (BUILD_MODES as readonly string[]).includes(value);

export const normaliseBuildMode = (input: unknown): BuildMode => {
  if (!isBuildMode(input)) {
    throw new BuildModeInputError('buildMode must be one of local, remote, balanced, or maximum-effort');
  }
  return input;
};

const parseStoredBuildMode = (text: string): { buildMode: BuildMode; updatedAt?: string } => {
  const raw = JSON.parse(text) as unknown;
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new Error('stored build mode must be an object');
  }
  const value = raw as Record<string, unknown>;
  if (value.schemaVersion !== undefined && value.schemaVersion !== 1) {
    throw new Error('unsupported build mode schemaVersion');
  }
  return {
    buildMode: normaliseBuildMode(value.buildMode),
    updatedAt: typeof value.updatedAt === 'string' && value.updatedAt.length > 0 && value.updatedAt.length <= UPDATED_AT_MAX_LENGTH
      ? value.updatedAt
      : undefined,
  };
};

const requireFeature = (config: AppConfig): NonNullable<AppConfig['buildMode']> => {
  if (!config.buildMode) {
    throw new Error('the Nix build mode dashboard is not enabled on this server');
  }
  return config.buildMode;
};

const buildModeResponse = async (config: AppConfig): Promise<BuildModeResponse> => {
  const feature = requireFeature(config);
  let current: BuildModeResponse['current'] = { buildMode: normaliseBuildMode(feature.defaultMode) };
  let warning: string | undefined;
  try {
    current = parseStoredBuildMode(await readFile(feature.stateFile, 'utf8'));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      warning = `the stored Nix build mode is invalid and the vars.nix default is in effect (${error instanceof Error ? error.message : String(error)})`;
    }
  }
  return {
    available: true,
    current,
    defaultMode: normaliseBuildMode(feature.defaultMode),
    modes: BUILD_MODES.map((value) => ({
      value,
      label: value,
      description: BUILD_MODE_DESCRIPTIONS[value],
    })),
    ...(warning ? { warning } : {}),
  };
};

export const getBuildMode = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<BuildModeResponse> => {
  requireBuildModeAdmin(config, headers);
  return buildModeResponse(config);
};

const runApplyHelper = (command: string, sudoPath: string, payload: { buildMode: BuildMode }): Promise<{ buildMode: BuildMode; updatedAt?: string }> =>
  new Promise((resolve, reject) => {
    const child = spawn(sudoPath, ['-n', command], {
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', (error) => {
      reject(new Error(`build mode helper exited before starting: ${error instanceof Error ? error.message : String(error)}`));
    });
    child.on('close', (code) => {
      const output = Buffer.concat(stdout).toString('utf8').trim();
      if (code === 0) {
        try {
          resolve(parseStoredBuildMode(output));
          return;
        } catch (error) {
          reject(new Error(`build mode helper returned an invalid mode: ${error instanceof Error ? error.message : String(error)}`));
          return;
        }
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `build mode helper exited with status ${code}`));
    });

    child.stdin.end(`${JSON.stringify(payload)}\n`);
  });

export const applyBuildMode = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  input: unknown,
): Promise<BuildModeResponse> => {
  requireBuildModeAdmin(config, headers);
  const feature = requireFeature(config);
  if (!feature.applyCommand) {
    throw new Error('Nix build mode updates are not enabled on this server');
  }
  const buildMode = normaliseBuildMode((input as { buildMode?: unknown } | null)?.buildMode);
  await runApplyHelper(feature.applyCommand, config.sudoPath, { buildMode });
  return buildModeResponse(config);
};
