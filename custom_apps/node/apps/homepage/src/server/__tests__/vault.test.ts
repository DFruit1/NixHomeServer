import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execPath } from 'node:process';
import { beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig, HomepageConfig } from '../config.js';
import { VaultHttpError, buildVaultStatus, listVaultFeatures, vaultFreshrssPassword, vaultKavitaKeysGet, vaultKavitaKeysMutate, vaultLock, vaultSshKeyAdd, vaultSshKeys, vaultSyncthingKeyGet, vaultSyncthingKeyRotate, vaultUnlock } from '../vault.js';
import { VAULT_COOKIE_NAME, attemptVaultUnlock } from '../vaultSession.js';

const validPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';

type VaultOverrides = Partial<HomepageConfig['vault']>;

const buildConfig = async (options: {
  admin?: boolean;
  adminUsers?: string[];
  groups?: string[];
  vault?: VaultOverrides;
  disabledVault?: boolean;
} = {}): Promise<{ config: AppConfig; dir: string }> => {  const dir = await mkdtemp(join(tmpdir(), 'homepage-vault-'));
  const sudo = join(dir, 'sudo.mjs');
  await writeFile(
    sudo,
    `#!${execPath}
import { stdout } from 'node:process';
const args = process.argv.slice(2);
if (args[0] === '-n') args.shift();
const command = args.shift();
const commandArgs = args;
if (command.endsWith('homepage-sftp-key-list')) {
  stdout.write('256 SHA256:AbCdEf123456 laptop (ED25519)\\n256 SHA256:AbCdEf123456 phone (ED25519)\\n');
} else if (command.endsWith('homepage-syncthing-api-key')) {
  stdout.write(commandArgs[0] === 'regenerate' ? 'new-syncthing-key' : 'current-syncthing-key');
} else if (command.endsWith('homepage-freshrss-api-password')) {
  let input = '';
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    if (!/^[A-Za-z0-9]{16,128}$/.test(input.trim())) {
      process.stderr.write('invalid freshrss api password payload\\n');
      process.exit(1);
    }
    stdout.write('freshrss api password updated for ' + commandArgs[0] + '\\n');
  });
} else if (command.endsWith('homepage-kavita-keys')) {
  let input = '';
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    const payload = JSON.parse(input || '{}');
    if (payload.action === 'list') {
      stdout.write(JSON.stringify({ keys: [{ id: 7, name: 'opds', key: 'kavitaKey123', createdAtUtc: '2026-01-01T00:00:00Z', expiresAtUtc: null, lastAccessedAtUtc: null }] }));
    } else if (payload.action === 'create') {
      stdout.write(JSON.stringify({ key: { id: 9, name: payload.name, key: 'createdKey456' } }));
    } else if (payload.action === 'rotate') {
      stdout.write(JSON.stringify({ key: { id: payload.authKeyId, name: 'opds', key: 'rotatedKey789' } }));
    } else if (payload.action === 'delete') {
      stdout.write(JSON.stringify({ deleted: payload.authKeyId }));
    } else {
      process.stderr.write('action must be list, create, rotate, or delete\\n');
      process.exit(1);
    }
  });
} else if (command.endsWith('homepage-install-sftp-key')) {
  let input = '';
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    if (!input.startsWith('ssh-ed25519 ')) {
      process.stderr.write('invalid OpenSSH public key\\n');
      process.exit(1);
    }
    stdout.write('saved /persist/appdata/files-sftp-authorized-keys/user owner=root:root mode=644 registered-keys=2\\n');
  });
} else {
  process.stderr.write('unexpected command ' + command + '\\n');
  process.exit(1);
}
`,
  );
  await chmod(sudo, 0o755);

  const vault = options.disabledVault
    ? undefined
    : {
        enabled: true,
        kanidmBaseUrl: 'https://id.example.test',
        sessionTtlSeconds: 900,
        idleTtlSeconds: 300,
        freshrssWebUrl: 'https://rss.example.test',
        kavitaWebUrl: 'https://books.example.test',
        features: {
          sshKeys: { enabled: true, requiredAnyGroups: ['files-sftp-users'] },
          syncthingApiKey: { enabled: true, adminOnly: true },
          freshrssApiPassword: { enabled: true, requiredAnyGroups: ['freshrss-users'] },
          kavitaApiKeys: { enabled: true, requiredAnyGroups: ['kavita-users'] },
        },
        ...options.vault,
      } as HomepageConfig['vault'];

  const config: AppConfig = {
    host: '127.0.0.1',
    port: 8084,
    staticDir: dir,
    devUser: 'dsaw',
    sudoPath: sudo,
    sftpKeyInstallCommand: `${dir}/fake-homepage-install-sftp-key`,
    sftpKeyListCommand: `${dir}/fake-homepage-sftp-key-list`,
    vaultSyncthingKeyCommand: `${dir}/fake-homepage-syncthing-api-key`,
    vaultFreshrssPasswordCommand: `${dir}/fake-homepage-freshrss-api-password`,
    vaultKavitaKeysCommand: `${dir}/fake-homepage-kavita-keys`,
    vaultKanidmUrl: 'https://id.example.test:8443',
    homepage: {
      brandName: 'Test Home',
      domain: 'example.test',
      services: [],
      folderGuides: [],
      adminGuide: [],
      adminUsers: options.adminUsers ?? (options.admin ? ['dsaw'] : []),
      adminGroups: [],
      vault,
    },
  };
  return { config, dir };
};

const user = (groups: string[], username = 'dsaw') => ({ username, groups });
const headersFor = (cookie?: string, groups?: string) => ({
  'x-forwarded-preferred-username': 'dsaw',
  ...(groups ? { 'x-forwarded-groups': groups } : {}),
  ...(cookie ? { cookie } : {}),
}) as never;

const allAccessGroups = 'files-sftp-users freshrss-users kavita-users';
const allAccessList = ['files-sftp-users', 'freshrss-users', 'kavita-users'];

const passwordFlowFetch = (): never =>
  (async (url: string, init?: { body?: string }) => {
    if (url.endsWith('/v1/logout')) {
      return { status: 200, headers: { get: () => null, getSetCookie: () => [] }, json: async () => ({}) };
    }
    const body = init?.body ? JSON.parse(init.body) : {};
    let state: unknown;
    if (body.step?.init2) {
      state = { choose: ['password'] };
    } else if (body.step?.begin) {
      state = { continue: ['password'] };
    } else {
      state = { success: 'vault-bearer' };
    }
    return {
      status: 200,
      headers: { get: () => null, getSetCookie: () => [] },
      json: async () => ({ sessionid: 'x', state }),
    };
  }) as never;

const unlock = async (config: AppConfig): Promise<string> => {
  const outcome = await attemptVaultUnlock(
    config,
    headersFor(undefined, allAccessGroups),
    user(allAccessList),
    { password: 'pw' },
    passwordFlowFetch(),
  );
  expect(outcome.kind).toBe('unlocked');
  return (outcome as { token: string }).token;
};

describe('vault feature catalog', () => {
  it('lists every configured feature with per-group access', async () => {
    const { config, dir } = await buildConfig({ adminUsers: ['boss'] });
    const member = user(['freshrss-users', 'kavita-users']);
    const features = listVaultFeatures(config, member);
    expect(features.map((feature) => feature.id)).toEqual(['sshKeys', 'syncthingApiKey', 'freshrssApiPassword', 'kavitaApiKeys']);
    const byId = Object.fromEntries(features.map((feature) => [feature.id, feature]));
    expect(byId.sshKeys.allowed).toBe(false);
    expect(byId.syncthingApiKey.allowed).toBe(false);
    expect(byId.freshrssApiPassword.allowed).toBe(true);
    expect(byId.kavitaApiKeys.allowed).toBe(true);
    expect(byId.freshrssApiPassword.webUrl).toBe('https://rss.example.test');

    const adminFeatures = Object.fromEntries(listVaultFeatures(config, user([], 'boss')).map((feature) => [feature.id, feature]));
    expect(adminFeatures.syncthingApiKey.allowed).toBe(true);
    expect(adminFeatures.syncthingApiKey.adminOnly).toBe(true);
    expect(adminFeatures.sshKeys.allowed).toBe(false);
    expect(adminFeatures.freshrssApiPassword.allowed).toBe(false);
  });

  it('hides disabled features and honours adminOnly=false', async () => {
    const { config, dir } = await buildConfig({
      adminUsers: ['dsaw'],
      vault: {
        features: {
          sshKeys: { enabled: false },
          syncthingApiKey: { enabled: true, adminOnly: false },
          freshrssApiPassword: { enabled: true },
          kavitaApiKeys: { enabled: false },
        },
      },
    });
    const features = listVaultFeatures(config, user(['files-sftp-users']));
    expect(features.map((feature) => feature.id)).toEqual(['syncthingApiKey', 'freshrssApiPassword']);
    expect(features[0].adminOnly).toBe(false);
    expect(features[0].allowed).toBe(true);
    await rm(dir, { recursive: true, force: true });
  });
});

describe('vault endpoints', () => {
  let dir: string;
  let config: AppConfig;

  beforeEach(async () => {
    const built = await buildConfig({ admin: true, groups: [] });
    dir = built.dir;
    config = built.config;
  });

  it('guards feature endpoints behind the unlock session and group gates', async () => {
    await expect(vaultSyncthingKeyGet(config, headersFor(undefined, allAccessGroups))).rejects.toMatchObject({ status: 401 });
    const error = await vaultSshKeys(config, headersFor()).catch((caught) => caught);
    expect(error).toBeInstanceOf(VaultHttpError);
    expect(error.status).toBe(403);
    const kavitaError = await vaultKavitaKeysGet(config, headersFor()).catch((caught) => caught);
    expect(kavitaError).toBeInstanceOf(VaultHttpError);
    expect(kavitaError.status).toBe(403);
  });

  it('returns an unlocked status with expiry after a successful unlock', async () => {
    const token = await unlock(config);
    const status = buildVaultStatus(config, headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups));
    expect(status.unlocked).toBe(true);
    const byId = Object.fromEntries(status.features.map((feature) => [feature.id, feature]));
    expect(byId.syncthingApiKey.allowed).toBe(true);
    expect(byId.sshKeys.allowed).toBe(true);
    expect(status.sessionTtlSeconds).toBe(900);
    expect(status.idleTtlSeconds).toBe(300);
  });

  it('rejects a session that belongs to a different user', async () => {
    const token = await unlock(config);
    const freshrssUser = {
      'x-forwarded-preferred-username': 'mallory',
      'x-forwarded-groups': 'freshrss-users',
      cookie: `${VAULT_COOKIE_NAME}=${token}`,
    } as never;
    await expect(vaultFreshrssPassword(config, freshrssUser)).rejects.toMatchObject({ status: 401 });
    const status = buildVaultStatus(config, freshrssUser);
    expect(status.unlocked).toBe(false);
  });

  it('clears the session on lock', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    const result = vaultLock(config, headers);
    expect(result.clearSessionCookie).toBe(true);
    expect(buildVaultStatus(config, headers).unlocked).toBe(false);
  });

  it('lists and adds SSH public keys through the helpers', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    const list = await vaultSshKeys(config, headers);
    expect(list.body).toEqual({ ok: true, keys: ['256 SHA256:AbCdEf123456 laptop (ED25519)', '256 SHA256:AbCdEf123456 phone (ED25519)'] });

    const added = await vaultSshKeyAdd(config, headers, { publicKey: validPublicKey });
    expect(added.body).toMatchObject({ ok: true, details: expect.stringContaining('registered-keys=2') });

    await expect(vaultSshKeyAdd(config, headers, { publicKey: 'not a key' })).rejects.toMatchObject({ status: 400 });
  });

  it('shows and rotates the Syncthing API key', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    expect((await vaultSyncthingKeyGet(config, headers)).body).toEqual({ ok: true, apiKey: 'current-syncthing-key' });
    expect((await vaultSyncthingKeyRotate(config, headers)).body).toEqual({ ok: true, apiKey: 'new-syncthing-key' });
  });

  it('registers a FreshRSS API password for the signed-in user', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    const result = await vaultFreshrssPassword(config, headers);
    const body = result.body as { ok: boolean; username: string; password: string; greaderUrl: string };
    expect(body.ok).toBe(true);
    expect(body.username).toBe('dsaw');
    expect(body.password).toMatch(/^[A-Za-z0-9]{32}$/);
    expect(body.greaderUrl).toBe('https://rss.example.test/api/greader.php');
  });

  it('performs Kavita key list, create, rotate, and delete', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    const list = await vaultKavitaKeysGet(config, headers);
    expect((list.body as { keys: Array<{ name: string }> }).keys[0].name).toBe('opds');

    const created = await vaultKavitaKeysMutate(config, headers, { action: 'create', name: 'Tablet reader' });
    expect((created.body as { key: { name: string } }).key.name).toBe('Tablet reader');

    const rotated = await vaultKavitaKeysMutate(config, headers, { action: 'rotate', authKeyId: 7 });
    expect((rotated.body as { key: { key: string } }).key.key).toBe('rotatedKey789');

    const deleted = await vaultKavitaKeysMutate(config, headers, { action: 'delete', authKeyId: 7 });
    expect(deleted.body).toEqual({ ok: true, deleted: 7 });
  });

  it('validates Kavita key mutation input', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    await expect(vaultKavitaKeysMutate(config, headers, { action: 'explode' })).rejects.toMatchObject({ status: 400 });
    await expect(vaultKavitaKeysMutate(config, headers, { action: 'create', name: 'bad; name' })).rejects.toMatchObject({ status: 400 });
    await expect(vaultKavitaKeysMutate(config, headers, { action: 'rotate', authKeyId: -1 })).rejects.toMatchObject({ status: 400 });
    await expect(vaultKavitaKeysMutate(config, headers, { action: 'rotate' })).rejects.toMatchObject({ status: 400 });
  });

  it('enforces per-feature group gates', async () => {
    const token = await unlock(config);
    void token;
    const limitedConfig: AppConfig = {
      ...config,
      homepage: {
        ...config.homepage,
        adminUsers: [],
        vault: {
          ...(config.homepage.vault as NonNullable<AppConfig['homepage']['vault']>),
          features: {
            sshKeys: { enabled: true, requiredAnyGroups: ['files-sftp-users'] },
            syncthingApiKey: { enabled: true, adminOnly: true },
            freshrssApiPassword: { enabled: true, requiredAnyGroups: ['freshrss-users'] },
            kavitaApiKeys: { enabled: true, requiredAnyGroups: ['kavita-users'] },
          },
        },
      },
    };
    const member = { username: 'dsaw', groups: ['freshrss-users'] };
    const outcome = await attemptVaultUnlock(
      limitedConfig,
      {
        'x-forwarded-preferred-username': 'dsaw',
        'x-forwarded-groups': 'freshrss-users',
      } as never,
      member,
      { password: 'pw' },
      passwordFlowFetch(),
    );
    expect(outcome.kind).toBe('unlocked');
    const memberToken = (outcome as { token: string }).token;
    const memberSession = {
      'x-forwarded-preferred-username': 'dsaw',
      'x-forwarded-groups': 'freshrss-users',
      cookie: `${VAULT_COOKIE_NAME}=${memberToken}`,
    } as never;
    await expect(vaultFreshrssPassword(limitedConfig, memberSession)).resolves.toMatchObject({ status: 200 });
    await expect(vaultSyncthingKeyGet(limitedConfig, memberSession)).rejects.toMatchObject({ status: 403 });
    await expect(vaultKavitaKeysGet(limitedConfig, memberSession)).rejects.toMatchObject({ status: 403 });
    await expect(vaultSshKeys(limitedConfig, memberSession)).rejects.toMatchObject({ status: 403 });
  });

  it('returns 404 for features that are disabled', async () => {
    const token = await unlock(config);
    const headers = headersFor(`${VAULT_COOKIE_NAME}=${token}`, allAccessGroups);
    const disabledConfig: AppConfig = {
      ...config,
      vaultSyncthingKeyCommand: undefined,
      vaultKavitaKeysCommand: undefined,
      sftpKeyListCommand: undefined,
      vaultFreshrssPasswordCommand: undefined,
    };
    for (const attempt of [
      vaultSyncthingKeyGet(disabledConfig, headers),
      vaultKavitaKeysGet(disabledConfig, headers),
      vaultSshKeys(disabledConfig, headers),
      vaultFreshrssPassword(disabledConfig, headers),
    ]) {
      await expect(attempt).rejects.toMatchObject({ status: 404 });
    }
  });
});
