import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { IncomingHttpHeaders } from 'node:http';
import { isHomepageAdmin, hasRequiredGroups } from './homepageData.js';
import type { AppConfig } from './config.js';
import { installSftpPublicKey, normalisePublicKey } from './sftpKey.js';
import type { CurrentUser, VaultFeature, VaultFeatureId, VaultStatus } from '../shared/types.js';
import {
  VaultHttpError,
  activeVaultSessionForUser,
  attemptVaultUnlock,
  clearVaultSessionCookie,
  endVaultSession,
  setVaultSessionCookie,
  vaultSessionExpiresAt,
  assertVaultUnlocked,
} from './vaultSession.js';
import { currentUserFromHeaders } from './auth.js';

export { VaultHttpError };

const FEATURE_NAMES: Record<VaultFeatureId, string> = {
  sshKeys: 'SFTP device keys',
  syncthingApiKey: 'Syncthing',
  freshrssApiPassword: 'FreshRSS',
  kavitaApiKeys: 'Kavita',
};

const FEATURE_DESCRIPTIONS: Record<VaultFeatureId, string> = {
  sshKeys: 'Add a key for each computer, phone, or tablet that connects to your files over SFTP or SSHFS.',
  syncthingApiKey: 'A key for scripts and tools that control the server\u2019s Syncthing.',
  freshrssApiPassword: 'A password that feed reader apps use to sign in as you.',
  kavitaApiKeys: 'Keys that reading apps use to sign in as you.',
};

export type VaultHttpResponse = {
  status: number;
  body: unknown;
  sessionToken?: string;
  clearSessionCookie?: boolean;
};

const vaultGate = (config: AppConfig, feature: VaultFeatureId) => config.homepage.vault?.features?.[feature];

export const vaultFeatureAllowed = (config: AppConfig, user: CurrentUser, feature: VaultFeatureId): boolean => {
  const gate = vaultGate(config, feature);
  if (!gate?.enabled) {
    return false;
  }
  if (feature === 'syncthingApiKey' && gate.adminOnly !== false) {
    return isHomepageAdmin(config, user);
  }
  return hasRequiredGroups(user.groups, gate.requiredAllGroups, gate.requiredAnyGroups);
};

export const listVaultFeatures = (config: AppConfig, user: CurrentUser): VaultFeature[] => {
  const vault = config.homepage.vault;
  if (!vault) {
    return [];
  }
  const order: VaultFeatureId[] = ['sshKeys', 'syncthingApiKey', 'freshrssApiPassword', 'kavitaApiKeys'];
  const webUrls: Partial<Record<VaultFeatureId, string | undefined>> = {
    freshrssApiPassword: vault.freshrssWebUrl,
    kavitaApiKeys: vault.kavitaWebUrl,
  };
  return order.flatMap((id) => {
    const gate = vault.features?.[id];
    if (!gate?.enabled) {
      return [];
    }
    return [{
      id,
      name: FEATURE_NAMES[id],
      description: FEATURE_DESCRIPTIONS[id],
      allowed: vaultFeatureAllowed(config, user, id),
      adminOnly: id === 'syncthingApiKey' ? gate.adminOnly !== false : undefined,
      webUrl: webUrls[id],
    }];
  });
};

const requireUser = (config: AppConfig, headers: IncomingHttpHeaders): CurrentUser => {
  const user = currentUserFromHeaders(headers, config.devUser);
  const vault = config.homepage.vault;
  if (!vault) {
    throw new VaultHttpError('vault is not enabled', 404);
  }
  return user;
};

const requireUnlockedFeature = (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  user: CurrentUser,
  feature: VaultFeatureId,
): void => {
  if (!vaultFeatureAllowed(config, user, feature)) {
    throw new VaultHttpError('not authorised: your account does not have access to this feature', 403);
  }
  assertVaultUnlocked(config, headers, user);
};

const requireCommand = (command: string | undefined, what: string): string => {
  if (!command) {
    throw new VaultHttpError(`${what} is not enabled on the server`, 404);
  }
  return command;
};

const runHelperCommand = (config: AppConfig, command: string, args: string[], input?: string): Promise<string> =>
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
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString('utf8'));
        return;
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `${command} exited with status ${code}`));
    });
    child.stdin.end(input ?? '');
  });

const freshrssPasswordAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

const generateFreshrssPassword = (): string => {
  const bytes = randomBytes(32);
  let password = '';
  for (const byte of bytes) {
    password += freshrssPasswordAlphabet[byte % freshrssPasswordAlphabet.length];
  }
  return password;
};

export const buildVaultStatus = (config: AppConfig, headers: IncomingHttpHeaders): VaultStatus => {
  const user = requireUser(config, headers);
  const vault = config.homepage.vault;
  const unlocked = activeVaultSessionForUser(config, headers, user);
  const { expiresAt, idleExpiresAt } = unlocked ? vaultSessionExpiresAt(config, headers) : {};
  return {
    unlocked,
    features: listVaultFeatures(config, user),
    expiresAt: expiresAt !== undefined ? new Date(expiresAt).toISOString() : undefined,
    idleExpiresAt: idleExpiresAt !== undefined ? new Date(idleExpiresAt).toISOString() : undefined,
    sessionTtlSeconds: vault?.sessionTtlSeconds,
    idleTtlSeconds: vault?.idleTtlSeconds,
  };
};

export const vaultUnlock = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  body: { password?: unknown; totp?: unknown; pendingId?: unknown },
): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  const outcome = await attemptVaultUnlock(config, headers, user, body);
  switch (outcome.kind) {
    case 'unlocked':
      return {
        status: 200,
        body: { ok: true, expiresAt: new Date(outcome.expiresAt).toISOString() },
        sessionToken: outcome.token,
      };
    case 'totp-required':
      return { status: 200, body: { ok: false, totpRequired: true, pendingId: outcome.pendingId } };
    case 'denied':
      return { status: 401, body: { ok: false, error: outcome.message || 'That password or code was not accepted.' } };
    case 'locked-out':
      return {
        status: 429,
        body: { ok: false, error: 'too many failed attempts; try again later', retryAfterSeconds: outcome.retryAfterSeconds },
      };
    case 'error':
      return { status: 503, body: { ok: false, error: outcome.message } };
  }
};

export const vaultLock = (config: AppConfig, headers: IncomingHttpHeaders): VaultHttpResponse => {
  requireUser(config, headers);
  endVaultSession(config, headers);
  return { status: 200, body: { ok: true }, clearSessionCookie: true };
};

export const vaultSshKeys = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'sshKeys');
  const command = requireCommand(config.sftpKeyListCommand, 'SSH key registration');
  const output = await runHelperCommand(config, command, [user.username]);
  const keys = output.split('\n').map((line) => line.trimEnd()).filter((line) => line.length > 0);
  return { status: 200, body: { ok: true, keys } };
};

export const vaultSshKeyAdd = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  body: { publicKey?: unknown },
): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'sshKeys');
  let publicKey: string;
  try {
    publicKey = normalisePublicKey(body.publicKey);
  } catch (error) {
    throw new VaultHttpError(error instanceof Error ? error.message : 'invalid public key', 400);
  }
  const result = await installSftpPublicKey(config, user, publicKey);
  return { status: 200, body: result };
};

export const vaultSyncthingKeyGet = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'syncthingApiKey');
  const command = requireCommand(config.vaultSyncthingKeyCommand, 'Syncthing API key management');
  const apiKey = (await runHelperCommand(config, command, ['show'])).trim();
  if (!apiKey) {
    throw new Error('Syncthing API key command returned an empty key');
  }
  return { status: 200, body: { ok: true, apiKey } };
};

export const vaultSyncthingKeyRotate = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'syncthingApiKey');
  const command = requireCommand(config.vaultSyncthingKeyCommand, 'Syncthing API key management');
  const apiKey = (await runHelperCommand(config, command, ['regenerate'])).trim();
  if (!apiKey) {
    throw new Error('Syncthing API key command returned an empty key');
  }
  return { status: 200, body: { ok: true, apiKey } };
};

export const vaultFreshrssPassword = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'freshrssApiPassword');
  const command = requireCommand(config.vaultFreshrssPasswordCommand, 'FreshRSS API password management');
  const password = generateFreshrssPassword();
  await runHelperCommand(config, command, [user.username], `${password}\n`);
  const webUrl = config.homepage.vault?.freshrssWebUrl ?? '';
  return {
    status: 200,
    body: {
      ok: true,
      username: user.username,
      password,
      greaderUrl: webUrl ? `${webUrl.replace(/\/$/, '')}/api/greader.php` : '',
      serverUrl: webUrl,
    },
  };
};

const KAVITA_KEY_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/;

export const vaultKavitaKeysGet = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'kavitaApiKeys');
  const command = requireCommand(config.vaultKavitaKeysCommand, 'Kavita API key management');
  const output = await runHelperCommand(config, command, [user.username], JSON.stringify({ action: 'list' }));
  return { status: 200, body: { ok: true, ...parseKavitaHelperJson(output, 'Kavita API key list') } };
};

export const vaultKavitaKeysMutate = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  body: { action?: unknown; name?: unknown; authKeyId?: unknown },
): Promise<VaultHttpResponse> => {
  const user = requireUser(config, headers);
  requireUnlockedFeature(config, headers, user, 'kavitaApiKeys');
  const command = requireCommand(config.vaultKavitaKeysCommand, 'Kavita API key management');
  const action = body.action;
  if (action !== 'create' && action !== 'rotate' && action !== 'delete') {
    throw new VaultHttpError('action must be create, rotate, or delete', 400);
  }
  if (action === 'create') {
    if (typeof body.name !== 'string' || !KAVITA_KEY_NAME_PATTERN.test(body.name.trim())) {
      throw new VaultHttpError('key name must be 1-64 letters, numbers, spaces, dots, underscores, or hyphens', 400);
    }
  } else {
    if (typeof body.authKeyId !== 'number' || !Number.isInteger(body.authKeyId) || body.authKeyId <= 0) {
      throw new VaultHttpError('authKeyId must be a positive integer', 400);
    }
  }
  const payload = action === 'create'
    ? { action, name: (body.name as string).trim() }
    : { action, authKeyId: body.authKeyId };
  const output = await runHelperCommand(config, command, [user.username], JSON.stringify(payload));
  return { status: 200, body: { ok: true, ...parseKavitaHelperJson(output, 'Kavita API key operation') } };
};

const parseKavitaHelperJson = (output: string, what: string): Record<string, unknown> => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error(`${what} returned invalid output`);
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${what} returned invalid output`);
  }
  return parsed as Record<string, unknown>;
};
