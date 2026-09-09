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

// Kanidm 1.11 signs the auth session id as a JWS: mixed-case base64url. The
// value must be forwarded byte-for-byte — Kanidm resolves the auth session
// from this header first and never falls back to the cookie when a (corrupt)
// header is present.
const KANIDM_SESSION_JWS = 'eyJhbGciOiJFUzI1NiJ9.AbC12-_dEfGh3Ij4Kl5Mn6Op7Qr.StUv-_Wx8Yz9A';

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
    { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123; Path=/; HttpOnly'], sessionHeader: KANIDM_SESSION_JWS },
    { status: 200, state: { continue: ['password'] }, sessionHeader: KANIDM_SESSION_JWS },
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
      { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123; Path=/; HttpOnly'], sessionHeader: KANIDM_SESSION_JWS },
      { status: 200, state: { continue: ['password'] }, sessionHeader: KANIDM_SESSION_JWS },
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
    // The signed session id is forwarded byte-for-byte; case mangling breaks
    // every subsequent step against the real Kanidm.
    expect(requests[1].headers['x-kanidm-auth-session-id']).toBe(KANIDM_SESSION_JWS);
    expect(requests[2].body).toEqual({ step: { cred: { password: 'correct horse' } } });
    expect(requests[2].headers['x-kanidm-auth-session-id']).toBe(KANIDM_SESSION_JWS);
    expect(requests[3].headers.authorization).toBe('Bearer bearer-token-1');
  });

  it('also follows a server that explicitly requests password before TOTP', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa', 'passkey'] }, cookies: ['auth-session-id=totp1'], sessionHeader: KANIDM_SESSION_JWS },
      { status: 200, state: { continue: ['password'] }, sessionHeader: KANIDM_SESSION_JWS },
      { status: 200, state: { continue: ['totp'] }, sessionHeader: KANIDM_SESSION_JWS },
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
    expect(rightRequests[0].headers['x-kanidm-auth-session-id']).toBe(KANIDM_SESSION_JWS);
    expect(rightRequests[1].headers.authorization).toBe('Bearer bearer-token-2');

    const reused = await submitKanidmTotp(baseConfig(), pendingId, 'alice', '654321', kanidmFetchStub([
      { status: 200, state: { success: 'token' } },
    ]).fetchImpl);
    expect(reused.kind).toBe('denied');
  });

  it('unlocks with real Kanidm TOTP-first MFA and follows rotated session credentials', async () => {
    const username = 'totp-first-success';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa', 'passkey'] }, cookies: ['auth-session-id=init'], sessionHeader: KANIDM_SESSION_JWS },
      { status: 200, state: { continue: ['totp'] }, cookies: ['auth-session-id=begin'], sessionHeader: 'Signed.Begin-JWS' },
      { status: 200, state: { continue: ['password'] }, cookies: ['auth-session-id=after-totp'], sessionHeader: 'Signed.Totp-JWS' },
      { status: 200, state: { success: 'mfa-token' }, cookies: ['auth-session-id=complete'] },
    ]);
    const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'correct horse' }, stub.fetchImpl);
    expect(pending.kind).toBe('totp-required');
    // Kanidm rejects a password here: only the authenticator code is allowed.
    expect(stub.requests()).toHaveLength(2);
    expect(JSON.stringify(pending)).not.toContain('correct horse');
    if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');

    const unlocked = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), {
      pendingId: pending.pendingId, totp: '012345',
    }, stub.fetchImpl);
    expect(unlocked.kind).toBe('unlocked');
    const requests = stub.requests();
    expect(requests[2].body).toEqual({ step: { cred: { totp: 12345 } } });
    expect(requests[2].headers.cookie).toBe('auth-session-id=begin');
    expect(requests[2].headers['x-kanidm-auth-session-id']).toBe('Signed.Begin-JWS');
    expect(requests[3].body).toEqual({ step: { cred: { password: 'correct horse' } } });
    expect(requests[3].headers.cookie).toBe('auth-session-id=after-totp');
    expect(requests[3].headers['x-kanidm-auth-session-id']).toBe('Signed.Totp-JWS');
    expect(requests[4].url).toBe('https://id.example.test:8443/v1/logout');
    expect(requests[4].headers.authorization).toBe('Bearer mfa-token');
    expect(requests[4].headers.cookie).toBe('auth-session-id=complete');
    if (unlocked.kind !== 'unlocked') throw new Error('Expected an unlocked session');
    expect(activeVaultSessionForUser(baseConfig(), headersFor(username, `${VAULT_COOKIE_NAME}=${unlocked.token}`), user(username))).toBe(true);
  });

  it('does not send the retained password after a wrong TOTP', async () => {
    const username = 'totp-first-bad-code';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['totp'] } },
      { status: 200, state: { denied: 'incorrect totp' } },
    ]);
    const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'correct horse' }, stub.fetchImpl);
    expect(pending.kind).toBe('totp-required');
    if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');
    const denied = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), {
      pendingId: pending.pendingId, totp: '654321',
    }, stub.fetchImpl);
    expect(denied.kind).toBe('denied');
    expect(stub.requests().map((request) => request.body)).toEqual([
      { step: { init2: { username, issue: 'token', privileged: false } } },
      { step: { begin: 'passwordmfa' } },
      { step: { cred: { totp: 654321 } } },
    ]);
    const replay = await submitKanidmTotp(baseConfig(), pending.pendingId, username, '654321', stub.fetchImpl);
    expect(replay.kind).toBe('denied');
    expect(stub.requests()).toHaveLength(3);
  });

  it('does not unlock when a valid TOTP is followed by an incorrect password', async () => {
    const username = 'totp-first-bad-password';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['totp'] } },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { denied: 'incorrect password' } },
    ]);
    const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'wrong' }, stub.fetchImpl);
    expect(pending.kind).toBe('totp-required');
    if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');
    const denied = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), {
      pendingId: pending.pendingId, totp: '654321',
    }, stub.fetchImpl);
    expect(denied.kind).toBe('denied');
    expect(stub.requests()).toHaveLength(4);
    expect(stub.requests()[3].body).toEqual({ step: { cred: { password: 'wrong' } } });
    expect(denied).not.toHaveProperty('token');
  });

  it('recognizes TOTP offered alongside a structured security-key challenge', async () => {
    const username = 'totp-with-securitykey';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['totp', { securitykey: { publicKey: { challenge: 'test-challenge' } } }] } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'pw' }, stub.fetchImpl);
    expect(outcome.kind).toBe('totp-required');
    expect(stub.requests()).toHaveLength(2);
  });

  it('enforces the pending TOTP expiry during submission before the sweeper runs', async () => {
    const username = 'expired-totp';
    // Use password-first compatibility to isolate expiry from factor ordering.
    const start = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { continue: ['totp'] } },
    ]);
    const now = Date.now();
    const clock = vi.spyOn(Date, 'now').mockReturnValue(now);
    try {
      const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'pw' }, start.fetchImpl);
      expect(pending.kind).toBe('totp-required');
      if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');
      clock.mockReturnValue(now + 3 * 60 * 1000 + 1);
      const finish = kanidmFetchStub([{ status: 200, state: { success: 'expired-token' } }]);
      const outcome = await submitKanidmTotp(baseConfig(), pending.pendingId, username, '654321', finish.fetchImpl);
      expect(outcome.kind).toBe('denied');
      expect(finish.requests()).toHaveLength(0);
    } finally {
      clock.mockRestore();
    }
  });

  it('allows only one upstream submission when a pending TOTP is submitted concurrently', async () => {
    const username = 'concurrent-totp';
    const start = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { continue: ['totp'] } },
    ]);
    const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'pw' }, start.fetchImpl);
    expect(pending.kind).toBe('totp-required');
    if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');
    const finish = kanidmFetchStub([{ status: 200, state: { success: 'concurrent-token' } }]);
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const delayedFetch: FetchLike = async (url, init) => {
      await gate;
      return finish.fetchImpl(url, init);
    };
    const first = submitKanidmTotp(baseConfig(), pending.pendingId, username, '654321', delayedFetch);
    const replay = submitKanidmTotp(baseConfig(), pending.pendingId, username, '654321', delayedFetch);
    release();
    const outcomes = await Promise.all([first, replay]);
    expect(outcomes.map((outcome) => outcome.kind).sort()).toEqual(['denied', 'success']);
    expect(finish.requests().filter((request) => request.url.endsWith('/v1/auth'))).toHaveLength(1);
  });

  it('reports a Kanidm begin outage as an error rather than invalid credentials', async () => {
    const username = 'begin-outage';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 503, state: undefined },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'pw' }, stub.fetchImpl);
    expect(outcome.kind).toBe('error');
  });

  it('reports a Kanidm TOTP outage as an error rather than invalid credentials', async () => {
    const username = 'totp-outage';
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passwordmfa'] } },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { continue: ['totp'] } },
      { status: 503, state: undefined },
    ]);
    const pending = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), { password: 'pw' }, stub.fetchImpl);
    expect(pending.kind).toBe('totp-required');
    if (pending.kind !== 'totp-required') throw new Error('Expected a TOTP challenge');
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor(username), user(username), {
      pendingId: pending.pendingId, totp: '654321',
    }, stub.fetchImpl);
    expect(outcome.kind).toBe('error');
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

  it('explains when the account does not offer password authentication', async () => {
    const stub = kanidmFetchStub([
      { status: 200, state: { choose: ['passkey'] } },
    ]);
    const outcome = await attemptVaultUnlock(baseConfig(), headersFor('alice'), user('alice'), { password: 'whatever' }, stub.fetchImpl);
    expect(outcome).toEqual({ kind: 'error', message: 'This account does not offer password sign-in for the vault.' });
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

  it('locks the account even when source addresses rotate', async () => {
    const fetchImpl = kanidmFetchStub([
      { status: 200, state: { choose: ['password'] }, cookies: ['auth-session-id=abc123'] },
      { status: 200, state: { continue: ['password'] } },
      { status: 200, state: { denied: 'no' } },
    ]).fetchImpl;
    const config = baseConfig();
    const headersForIp = (ip: string): IncomingHttpHeaders => ({
      'x-forwarded-preferred-username': 'pru',
      'x-forwarded-for': ip,
    });
    // Four failures per address stay below the per-address lockout, so only
    // the account-level budget can stop the rotation.
    for (let index = 0; index < 20; index += 1) {
      const outcome = await attemptVaultUnlock(config, headersForIp(`10.0.0.${Math.floor(index / 4)}`), user('pru'), { password: 'wrong' }, fetchImpl);
      expect(outcome.kind).toBe(index === 19 ? 'locked-out' : 'denied');
    }
    const locked = await attemptVaultUnlock(config, headersForIp('10.0.0.99'), user('pru'), { password: 'wrong' }, fetchImpl);
    expect(locked.kind).toBe('locked-out');
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
