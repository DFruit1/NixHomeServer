import type { IncomingHttpHeaders, ServerResponse } from 'node:http';
import { describe, expect, it, vi } from 'vitest';
import type { AppConfig } from '../config.js';
import {
  VAULT_COOKIE_NAME,
  activeVaultSessionForUser,
  attemptVaultUnlock,
  clearVaultSessionCookie,
  endVaultSession,
  setVaultSessionCookie,
  submitKanidmTotp,
} from '../vaultSession.js';
import type { FetchLike } from '../vaultSession.js';

const baseConfig = (): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: '/tmp',
  vaultKanidmUrl: 'https://id.example.test:8443',
  sudoPath: '/bin/true',
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    adminUsers: [],
    adminGroups: [],
    vault: {
      enabled: true,
      kanidmBaseUrl: 'https://id.example.test',
      sessionTtlSeconds: 900,
      idleTtlSeconds: 300,
      features: {},
    },
  },
});

type RecordedRequest = { url: string; method: string; headers: Record<string, string>; body: unknown };

type StubResponse = { status: number; state: unknown; cookies?: string[]; sessionHeader?: string };

const kanidmFetchStub = (responses: StubResponse[]) => {
  const requests: RecordedRequest[] = [];
  let index = 0;
  const fetchImpl: FetchLike = async (url, init) => {
    if (url.endsWith('/v1/logout')) {
      requests.push({ url, method: init?.method ?? 'GET', headers: init?.headers ?? {}, body: null });
      return { status: 200, headers: { get: () => null }, json: async () => ({}) };
    }
    requests.push({
      url,
      method: init?.method ?? 'GET',
      headers: init?.headers ?? {},
      body: init?.body ? JSON.parse(init.body) : null,
    });
    const response = responses[Math.min(index, responses.length - 1)];
    index += 1;
    return {
      status: response.status,
      headers: {
        get: (name: string) => (name === 'x-kanidm-auth-session-id' ? response.sessionHeader ?? null : null),
        getSetCookie: () => response.cookies ?? [],
      },
      json: async () => ({ sessionid: '11111111-2222-3333-4444-555555555555', state: response.state }),
    };
  };
  return { fetchImpl, requests: () => requests };
};

const passwordOnlyServer = (): FetchLike =>
  kanidmFetchStub([
    { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123; Path=/; HttpOnly'] },
    { status: 200, state: { continue: ['password'] } },
    { status: 200, state: { success: 'bearer-token-1' } },
  ]).fetchImpl;

const user = (username: string) => ({ username, groups: [] as string[] });
const headersFor = (username: string, cookie?: string): IncomingHttpHeaders => ({
  'x-forwarded-preferred-username': username,
  ...(cookie ? { cookie } : {}),
});

const fakeResponse = (capture: (value: string) => void): ServerResponse =>
  ({
    setHeader: (_name: string, value: string) => capture(value),
  }) as unknown as ServerResponse;

describe('vault unlock via Kanidm', () => {
  it('completes a password-only unlock and revokes the Kanidm session', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123; Path=/; HttpOnly'] },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { success: 'bearer-token-1' } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'correct horse' }, stub.fetchImpl);
    expect(outcome.kind).toBe('unlocked');
    const requests = stub.requests();
    expect(requests.map((request) => request.url)).toEqual([
      'https://id.example.test:8443/v1/auth',
      'https://id.example.test:8443/v1/auth',
      'https://id.example.test:8443/v1/auth',
      'https://id.example.test:8443/v1/logout',
    ]);
    expect(requests[0].body).toEqual({ step: { init2: { username: 'alice', issue: 'token', privileged: false } } });
    expect(requests[1].body).toEqual({ step: { begin: 'password' } });
    expect(requests[1].headers.cookie).toBe('auth-session-id=abc123');
    expect(requests[2].body).toEqual({ step: { cred: { password: 'correct horse' } } });
    expect(requests[3].headers.authorization).toBe('Bearer bearer-token-1');
  });

  it('uses the passwordmfa mechanism and asks for a TOTP when the account requires it', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa', 'passkey'] }, cookies: ['auth-session-id=totp1'] },
      { status: 200, state: { continue: ['password', 'totp'] } },
      { status: 200, state: { continue: ['totp'] } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'correct horse' }, stub.fetchImpl);
    expect(outcome.kind).toBe('totp-required');
    const requests = stub.requests();
    expect(requests[1].body).toEqual({ step: { begin: 'passwordmfa' } });
    expect(requests[2].body).toEqual({ step: { cred: { password: 'correct horse' } } });
    const pendingId = outcome.kind === 'totp-required' ? outcome.pendingId : '';
    expect(pendingId).not.toBe('');

    const rightStub = kanidmFetchStub([
      { status: 200, state: { success: 'bearer-token-2' } },
    ]);
    const right = await submitKanidmTotp(baseConfig(), pendingId, 'alice', '654321', rightStub.fetchImpl);
    expect(right.kind).toBe('success');
    const rightRequests = rightStub.requests();
    expect(rightRequests[0].body).toEqual({ step: { cred: { totp: 654321 } } });
    expect(rightRequests[0].headers.cookie).toBe('auth-session-id=totp1');
    expect(rightRequests[1].headers.authorization).toBe('Bearer bearer-token-2');

    const reused = await submitKanidmTotp(baseConfig(), pendingId, 'alice', '654321', kanidmFetchStub([
      { status: 200, state: { success: 'token' } },
    ]).fetchImpl);
    expect(reused.kind).toBe('denied');
  });

  it('reports denial when the password is wrong', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123'] },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { denied: 'incorrect password' } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'wrong' }, stub.fetchImpl);
    expect(outcome.kind).toBe('denied');
  });

  it('reports denial for accounts without password authentication', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passkey'] } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'whatever' }, stub.fetchImpl);
    expect(outcome.kind).toBe('denied');
  });

  it('reports an error when Kanidm is unreachable', async () => {
    const fetchImpl: FetchLike = async () => {
      throw new Error('connect ECONNREFUSED');
    };
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'x' }, fetchImpl);
    expect(outcome.kind).toBe('error');
  });

  it('returns an error outcome when the vault is disabled', async () => {
    const config = baseConfig();
    config.homepage.vault = undefined;
    const outcome = await attemptVaultUnlock(config, headersFor('alice'), user('alice'), { password: 'x' }, passwordOnlyServer());
    expect(outcome.kind).toBe('error');
    expect((outcome as { message?: string }).message).toContain('not enabled');
  });

  it('locks the account after repeated failed attempts', async () => {
    const fetchImpl = kanidmFetchStub([
      { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123'] },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { denied: 'no' } },
    ]).fetchImpl;
    const config = baseConfig();
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const outcome = await attemptVaultUnlock(config, headersFor('frank'), user('frank'), { password: 'wrong' }, fetchImpl);
      expect(outcome.kind).toBe('denied');
    }
    const locked = await attemptVaultUnlock(config, headersFor('frank'), user('frank'), { password: 'wrong' }, fetchImpl);
    expect(locked.kind).toBe('locked-out');
    expect((locked as { retryAfterSeconds?: number }).retryAfterSeconds).toBeGreaterThan(0);
  });

  it('rejects an unlock body without a password', async () => {
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), {}, passwordOnlyServer());
    expect(outcome.kind).toBe('denied');
    expect((outcome as { message?: string }).message).toContain('password');
  });

  it('does not reuse a TOTP pending flow for another user', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] }, cookies: ['auth-session-id=flow1'] },
      { status: 200, state: { continue: ['totp'] } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('gina'), user('gina'), { password: 'pw' }, stub.fetchImpl);
    const pendingId = outcome.kind === 'totp-required' ? outcome.pendingId : '';
    const other = await submitKanidmTotp(baseConfig(), pendingId, 'henry', '654321', kanidmFetchStub([
      { status: 200, state: { success: 'token' } },
    ]).fetchImpl);
    expect(other.kind).toBe('denied');
  });
});

describe('vault session store', () => {
  it('mints a browser-session cookie with hardening attributes', async () => {
    const captured: string[] = [];
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('iris'), user('iris'), { password: 'pw' }, passwordOnlyServer());
    expect(outcome.kind).toBe('unlocked');
    setVaultSessionCookie(fakeResponse((value) => captured.push(value)), (outcome as { token: string }).token);
    expect(captured[0]).toContain(`${VAULT_COOKIE_NAME}=`);
    expect(captured[0]).toContain('HttpOnly');
    expect(captured[0]).toContain('Secure');
    expect(captured[0]).toContain('SameSite=Strict');
    expect(captured[0]).toContain('Path=/api/vault');
    expect(captured[0]).not.toContain('Max-Age');
    expect(captured[0]).not.toContain('Expires=');
    clearVaultSessionCookie(fakeResponse((value) => captured.push(value)));
    expect(captured[1]).toContain('Max-Age=0');
  });

  it('keeps sessions valid until the absolute TTL and invalidates them afterwards', async () => {
    const config = baseConfig();
    const outcome = await attemptVaultUnlock(config, headersFor('carol'), user('carol'), { password: 'pw' }, passwordOnlyServer());
    const token = (outcome as { token: string }).token;
    const sessionHeaders = headersFor('carol', `${VAULT_COOKIE_NAME}=${token}`);
    expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(true);

    vi.useFakeTimers();
    try {
      const mintedAt = Date.now();
      vi.setSystemTime(mintedAt + 200_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(true);
      vi.setSystemTime(mintedAt + 400_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(true);
      vi.setSystemTime(mintedAt + 600_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(true);
      vi.setSystemTime(mintedAt + 800_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(true);
      vi.setSystemTime(mintedAt + 1_000_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('carol'))).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it('expires idle sessions', async () => {
    const config = baseConfig();
    const outcome = await attemptVaultUnlock(config, headersFor('dave'), user('dave'), { password: 'pw' }, passwordOnlyServer());
    const token = (outcome as { token: string }).token;
    const sessionHeaders = headersFor('dave', `${VAULT_COOKIE_NAME}=${token}`);
    expect(activeVaultSessionForUser(config, sessionHeaders, user('dave'))).toBe(true);

    vi.useFakeTimers();
    try {
      const mintedAt = Date.now();
      vi.setSystemTime(mintedAt + 301_000);
      expect(activeVaultSessionForUser(config, sessionHeaders, user('dave'))).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it('binds the session to the SSO user and supports locking', async () => {
    const config = baseConfig();
    const outcome = await attemptVaultUnlock(config, headersFor('erin'), user('erin'), { password: 'pw' }, passwordOnlyServer());
    const token = (outcome as { token: string }).token;
    const sessionHeaders = headersFor('erin', `${VAULT_COOKIE_NAME}=${token}`);
    expect(activeVaultSessionForUser(config, sessionHeaders, user('mallory'))).toBe(false);
    expect(activeVaultSessionForUser(config, sessionHeaders, user('erin'))).toBe(true);
    expect(endVaultSession(config, sessionHeaders)).toBe(true);
    expect(activeVaultSessionForUser(config, sessionHeaders, user('erin'))).toBe(false);
  });

  it('ignores malformed session tokens', () => {
    const config = baseConfig();
    const headers = headersFor('alice', `${VAULT_COOKIE_NAME}=short; other=1`);
    expect(activeVaultSessionForUser(config, headers, user('alice'))).toBe(false);
  });
});
