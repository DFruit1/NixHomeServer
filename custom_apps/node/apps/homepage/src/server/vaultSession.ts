import { randomBytes } from 'node:crypto';
import type { IncomingHttpHeaders, ServerResponse } from 'node:http';
import type { AppConfig } from './config.js';
import type { CurrentUser } from '../shared/types.js';

export const VAULT_COOKIE_NAME = 'homepage-vault-session';
const VAULT_COOKIE_PATH = '/api/vault';
const KANIDM_COOKIE_NAME = 'auth-session-id';
const KANIDM_SESSION_HEADER = 'x-kanidm-auth-session-id';
const REQUEST_TIMEOUT_MS = 10_000;
const PENDING_TOTP_TTL_MS = 3 * 60 * 1000;
const MAX_PENDING_FLOWS = 20;
const MAX_SESSIONS_PER_USER = 5;
const MAX_SESSIONS_TOTAL = 200;
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_DURATION_MS = 5 * 60 * 1000;
const LOCKOUT_STATE_TTL_MS = 15 * 60 * 1000;

export type FetchLike = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
  },
) => Promise<{
  status: number;
  headers: {
    get: (name: string) => string | null;
    getSetCookie?: () => string[];
  };
  json: () => Promise<unknown>;
}>;

type VaultSession = {
  token: string;
  username: string;
  createdAt: number;
  expiresAt: number;
  lastSeenAt: number;
};

type PendingTotp = {
  id: string;
  username: string;
  cookie: string;
  sessionHeader?: string;
  createdAt: number;
};

type LoginAttemptState = {
  failures: number;
  lockedUntil: number;
  updatedAt: number;
};

export type VaultUnlockOutcome =
  | { kind: 'unlocked'; token: string; expiresAt: number }
  | { kind: 'totp-required'; pendingId: string }
  | { kind: 'denied'; message: string }
  | { kind: 'locked-out'; retryAfterSeconds: number }
  | { kind: 'error'; message: string };

export class VaultHttpError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

const sessions = new Map<string, VaultSession>();
const pendingTotps = new Map<string, PendingTotp>();
const loginAttempts = new Map<string, LoginAttemptState>();

let sweeperStarted = false;

const startSweeper = (): void => {
  if (sweeperStarted) {
    return;
  }
  sweeperStarted = true;
  const timer = setInterval(() => {
    const now = Date.now();
    for (const [token, session] of sessions) {
      if (now >= session.expiresAt || now - session.lastSeenAt > idleTtlMs()) {
        sessions.delete(token);
      }
    }
    for (const [id, pending] of pendingTotps) {
      if (now - pending.createdAt > PENDING_TOTP_TTL_MS) {
        pendingTotps.delete(id);
      }
    }
    for (const [key, state] of loginAttempts) {
      if (now - state.updatedAt > LOCKOUT_STATE_TTL_MS && now >= state.lockedUntil) {
        loginAttempts.delete(key);
      }
    }
  }, 60_000);
  timer.unref?.();
};

const vaultConfigOrUndefined = (config: AppConfig) => (config.homepage.vault?.enabled ? config.homepage.vault : undefined);

const idleTtlMs = (): number => 5 * 60 * 1000;

const configuredIdleTtlMs = (config: AppConfig): number => {
  const vault = vaultConfigOrUndefined(config);
  return vault ? vault.idleTtlSeconds * 1000 : idleTtlMs();
};

const sessionTtlMs = (config: AppConfig): number => {
  const vault = vaultConfigOrUndefined(config);
  return vault ? vault.sessionTtlSeconds * 1000 : 15 * 60 * 1000;
};

export const pruneVaultState = (config: AppConfig, now = Date.now()): void => {
  const idleTtl = configuredIdleTtlMs(config);
  for (const [token, session] of sessions) {
    if (now >= session.expiresAt || now - session.lastSeenAt > idleTtl) {
      sessions.delete(token);
    }
  }
  for (const [id, pending] of pendingTotps) {
    if (now - pending.createdAt > PENDING_TOTP_TTL_MS) {
      pendingTotps.delete(id);
    }
  }
  for (const [key, state] of loginAttempts) {
    if (now - state.updatedAt > LOCKOUT_STATE_TTL_MS && now >= state.lockedUntil) {
      loginAttempts.delete(key);
    }
  }
};

const parseCookies = (headerValue: string | undefined): Record<string, string> => {
  const cookies: Record<string, string> = {};
  if (!headerValue) {
    return cookies;
  }
  for (const part of headerValue.split(';')) {
    const separator = part.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    const name = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (name && !(name in cookies)) {
      try {
        cookies[name] = decodeURIComponent(value);
      } catch {
        cookies[name] = value;
      }
    }
  }
  return cookies;
};

export const getVaultSessionToken = (headers: IncomingHttpHeaders): string | undefined => {
  const cookies = parseCookies(headers.cookie);
  return cookies[VAULT_COOKIE_NAME];
};

export const lookupVaultSession = (config: AppConfig, headers: IncomingHttpHeaders): VaultSession | undefined => {
  startSweeper();
  const token = getVaultSessionToken(headers);
  if (!token || !/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    return undefined;
  }
  const session = sessions.get(token);
  if (!session) {
    return undefined;
  }
  const now = Date.now();
  if (now >= session.expiresAt || now - session.lastSeenAt > configuredIdleTtlMs(config)) {
    sessions.delete(token);
    return undefined;
  }
  session.lastSeenAt = now;
  return session;
};

export const activeVaultSessionForUser = (config: AppConfig, headers: IncomingHttpHeaders, user: CurrentUser): boolean => {
  const session = lookupVaultSession(config, headers);
  return Boolean(session && session.username === user.username);
};

const randomToken = (): string => randomBytes(32).toString('base64url');

const mintSession = (config: AppConfig, username: string): VaultSession => {
  const now = Date.now();
  const session: VaultSession = {
    token: randomToken(),
    username,
    createdAt: now,
    expiresAt: now + sessionTtlMs(config),
    lastSeenAt: now,
  };
  const userSessions = [...sessions.values()].filter((entry) => entry.username === username);
  userSessions.sort((a, b) => a.lastSeenAt - b.lastSeenAt);
  while (userSessions.length >= MAX_SESSIONS_PER_USER) {
    const oldest = userSessions.shift();
    if (oldest) {
      sessions.delete(oldest.token);
    }
  }
  while (sessions.size >= MAX_SESSIONS_TOTAL) {
    let oldest: VaultSession | undefined;
    for (const entry of sessions.values()) {
      if (!oldest || entry.lastSeenAt < oldest.lastSeenAt) {
        oldest = entry;
      }
    }
    if (!oldest) {
      break;
    }
    sessions.delete(oldest.token);
  }
  sessions.set(session.token, session);
  return session;
};

const loginAttemptKey = (username: string, remoteAddress: string): string => `${username}|${remoteAddress}`;

const remoteAddressOf = (headers: IncomingHttpHeaders): string => {
  const forwarded = headers['x-forwarded-for'];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  const candidate = (first ?? '').split(',', 1)[0]?.trim();
  return candidate || 'unknown';
};

const loginLockedRemainingMs = (key: string, now: number): number => {
  const state = loginAttempts.get(key);
  if (!state) {
    return 0;
  }
  if (now < state.lockedUntil) {
    return state.lockedUntil - now;
  }
  if (now - state.updatedAt > LOCKOUT_STATE_TTL_MS) {
    loginAttempts.delete(key);
  }
  return 0;
};

const recordFailedLogin = (key: string, now: number): void => {
  const state = loginAttempts.get(key) ?? { failures: 0, lockedUntil: 0, updatedAt: now };
  state.failures += 1;
  state.updatedAt = now;
  if (state.failures >= MAX_FAILED_ATTEMPTS) {
    state.lockedUntil = now + LOCKOUT_DURATION_MS;
    state.failures = 0;
  }
  loginAttempts.set(key, state);
};

export const getVaultSessionFromRequest = (config: AppConfig, headers: IncomingHttpHeaders): VaultSession | undefined =>
  lookupVaultSession(config, headers);

export const endVaultSession = (config: AppConfig, headers: IncomingHttpHeaders): boolean => {
  const token = getVaultSessionToken(headers);
  if (!token) {
    return false;
  }
  return sessions.delete(token);
};

const sessionCookieAttributes = `Path=${VAULT_COOKIE_PATH}; HttpOnly; Secure; SameSite=Strict`;

export const setVaultSessionCookie = (response: ServerResponse, token: string): void => {
  response.setHeader('set-cookie', `${VAULT_COOKIE_NAME}=${token}; ${sessionCookieAttributes}`);
};

export const clearVaultSessionCookie = (response: ServerResponse): void => {
  response.setHeader('set-cookie', `${VAULT_COOKIE_NAME}=; ${sessionCookieAttributes}; Max-Age=0`);
};

const mergeCookies = (current: string, additions: string[]): string => {
  const jar = new Map<string, string>();
  for (const entry of [current, ...additions]) {
    if (!entry) {
      continue;
    }
    for (const part of entry.split(';')) {
      const separator = part.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      const name = part.slice(0, separator).trim();
      const value = part.slice(separator + 1).trim();
      if (name) {
        jar.set(name, value);
      }
    }
  }
  return [...jar.entries()].map(([name, value]) => `${name}=${value}`).join('; ');
};

const collectKanidmCookies = (headers: { get: (name: string) => string | null; getSetCookie?: () => string[] }): string[] => {
  const raw = typeof headers.getSetCookie === 'function' ? headers.getSetCookie() : [];
  const cookies: string[] = [];
  for (const entry of raw) {
    const separator = entry.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    const name = entry.slice(0, separator).trim();
    if (name === KANIDM_COOKIE_NAME) {
      const end = entry.indexOf(';', separator);
      cookies.push(end === -1 ? entry.trim() : entry.slice(0, end).trim());
    }
  }
  return cookies;
};

type KanidmAuthState =
  | { kind: 'choose'; mechs: string[] }
  | { kind: 'continue'; allowed: string[] }
  | { kind: 'success'; token: string }
  | { kind: 'denied'; message: string };

const parseKanidmState = (body: unknown): KanidmAuthState | undefined => {
  if (typeof body !== 'object' || body === null) {
    return undefined;
  }
  const state = (body as { state?: unknown }).state;
  if (typeof state !== 'object' || state === null) {
    return undefined;
  }
  const entries = Object.entries(state as Record<string, unknown>);
  if (entries.length !== 1) {
    return undefined;
  }
  const [kind, value] = entries[0];
  if ((kind === 'choose' || kind === 'continue') && Array.isArray(value) && value.every((item) => typeof item === 'string')) {
    return kind === 'choose'
      ? { kind: 'choose', mechs: value as string[] }
      : { kind: 'continue', allowed: value as string[] };
  }
  if (kind === 'success' && typeof value === 'string') {
    return { kind: 'success', token: value };
  }
  if (kind === 'denied' && typeof value === 'string') {
    return { kind: 'denied', message: value };
  }
  return undefined;
};

const postKanidmAuth = async (
  fetchImpl: FetchLike,
  kanidmUrl: string,
  body: unknown,
  cookie: string,
  sessionHeader?: string,
): Promise<{ status: number; state: KanidmAuthState | undefined; cookies: string[]; sessionHeader?: string }> => {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    accept: 'application/json',
  };
  if (cookie) {
    headers.cookie = cookie;
  }
  if (sessionHeader) {
    headers[KANIDM_SESSION_HEADER] = sessionHeader;
  }
  const response = await fetchImpl(`${kanidmUrl}/v1/auth`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  const cookies = collectKanidmCookies(response.headers);
  const nextSessionHeader = response.headers.get(KANIDM_SESSION_HEADER)?.toLowerCase() ?? undefined;
  let bodyJson: unknown;
  try {
    bodyJson = await response.json();
  } catch {
    bodyJson = undefined;
  }
  return {
    status: response.status,
    state: parseKanidmState(bodyJson),
    cookies,
    sessionHeader: nextSessionHeader,
  };
};

const revokeKanidmSession = async (
  fetchImpl: FetchLike,
  kanidmUrl: string,
  bearerToken: string,
  cookie: string,
): Promise<void> => {
  try {
    await fetchImpl(`${kanidmUrl}/v1/logout`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${bearerToken}`,
        ...(cookie ? { cookie } : {}),
      },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch {
    return;
  }
};

export type KanidmAuthOutcome =
  | { kind: 'success' }
  | { kind: 'totp-required'; pendingId: string }
  | { kind: 'denied' };

export const startKanidmPasswordAuth = async (
  config: AppConfig,
  username: string,
  password: string,
  fetchImpl: FetchLike = fetch,
): Promise<KanidmAuthOutcome> => {
  const kanidmUrl = config.vaultKanidmUrl;
  if (!kanidmUrl) {
    throw new Error('vault identity verification is not configured');
  }
  let cookie = '';
  let sessionHeader: string | undefined;

  const init = await postKanidmAuth(
    fetchImpl,
    kanidmUrl,
    { step: { init2: { username, issue: 'token', privileged: false } } },
    '',
  );
  if (init.state?.kind === 'denied' || init.status === 401) {
    return { kind: 'denied' };
  }
  if (init.status !== 200 || init.state?.kind !== 'choose') {
    throw new Error('vault identity verification is unavailable');
  }
  const mechs = init.state.mechs;
  if (!mechs.includes('password') && !mechs.includes('passwordmfa')) {
    return { kind: 'denied' };
  }
  const mech = mechs.includes('passwordmfa') ? 'passwordmfa' : 'password';
  cookie = mergeCookies(cookie, init.cookies);

  const begin = await postKanidmAuth(fetchImpl, kanidmUrl, { step: { begin: mech } }, cookie, sessionHeader);
  if (begin.state?.kind === 'denied' || begin.status !== 200 || begin.state?.kind !== 'continue') {
    return { kind: 'denied' };
  }
  cookie = mergeCookies(cookie, [...init.cookies, ...begin.cookies]);
  sessionHeader = begin.sessionHeader ?? sessionHeader;

  const cred = await postKanidmAuth(
    fetchImpl,
    kanidmUrl,
    { step: { cred: { password } } },
    cookie,
    sessionHeader,
  );
  if (cred.state?.kind === 'denied') {
    return { kind: 'denied' };
  }
  if (cred.status !== 200 || !cred.state) {
    throw new Error('vault identity verification is unavailable');
  }
  cookie = mergeCookies(cookie, cred.cookies);
  sessionHeader = cred.sessionHeader ?? sessionHeader;

  if (cred.state.kind === 'success') {
    await revokeKanidmSession(fetchImpl, kanidmUrl, cred.state.token, cookie);
    return { kind: 'success' };
  }
  if (cred.state.kind === 'continue' && cred.state.allowed.includes('totp')) {
    return registerPendingTotp(username, cookie, sessionHeader);
  }
  return { kind: 'denied' };
};

export const submitKanidmTotp = async (
  config: AppConfig,
  pendingId: string,
  username: string,
  totp: string,
  fetchImpl: FetchLike = fetch,
): Promise<KanidmAuthOutcome> => {
  const kanidmUrl = config.vaultKanidmUrl;
  if (!kanidmUrl) {
    throw new Error('vault identity verification is not configured');
  }
  const pending = pendingTotps.get(pendingId);
  if (!pending || pending.username !== username) {
    return { kind: 'denied' };
  }
  const code = totp.trim();
  if (!/^\d{6}$/.test(code)) {
    return { kind: 'denied' };
  }
  const cred = await postKanidmAuth(
    fetchImpl,
    kanidmUrl,
    { step: { cred: { totp: Number.parseInt(code, 10) } } },
    pending.cookie,
    pending.sessionHeader,
  );
  pendingTotps.delete(pendingId);
  if (cred.state?.kind === 'denied') {
    return { kind: 'denied' };
  }
  if (cred.status !== 200 || cred.state?.kind !== 'success') {
    return { kind: 'denied' };
  }
  await revokeKanidmSession(fetchImpl, kanidmUrl, cred.state.token, pending.cookie);
  return { kind: 'success' };
};

const registerPendingTotp = (username: string, cookie: string, sessionHeader?: string): KanidmAuthOutcome => {
  const now = Date.now();
  for (const [id, pending] of pendingTotps) {
    if (now - pending.createdAt > PENDING_TOTP_TTL_MS || pending.username === username) {
      pendingTotps.delete(id);
    }
  }
  while (pendingTotps.size >= MAX_PENDING_FLOWS) {
    let oldestId: string | undefined;
    let oldestAt = Number.POSITIVE_INFINITY;
    for (const [id, pending] of pendingTotps) {
      if (pending.createdAt < oldestAt) {
        oldestAt = pending.createdAt;
        oldestId = id;
      }
    }
    if (!oldestId) {
      break;
    }
    pendingTotps.delete(oldestId);
  }
  const pending: PendingTotp = {
    id: randomBytes(16).toString('base64url'),
    username,
    cookie,
    sessionHeader,
    createdAt: now,
  };
  pendingTotps.set(pending.id, pending);
  return { kind: 'totp-required', pendingId: pending.id };
};

const passwordRuleOk = (password: unknown): password is string =>
  typeof password === 'string' && password.length >= 1 && password.length <= 1024;

export const attemptVaultUnlock = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  user: CurrentUser,
  body: { password?: unknown; totp?: unknown; pendingId?: unknown },
  fetchImpl?: FetchLike,
): Promise<VaultUnlockOutcome> => {
  startSweeper();
  const vault = vaultConfigOrUndefined(config);
  if (!vault) {
    return { kind: 'error', message: 'vault is not enabled' };
  }
  const key = loginAttemptKey(user.username, remoteAddressOf(headers));
  const now = Date.now();
  const remainingMs = loginLockedRemainingMs(key, now);
  if (remainingMs > 0) {
    return { kind: 'locked-out', retryAfterSeconds: Math.ceil(remainingMs / 1000) };
  }

  const hasTotpFlow = typeof body.pendingId === 'string' && body.pendingId.length > 0;
  const password = passwordRuleOk(body.password) ? body.password : undefined;
  const totp = typeof body.totp === 'string' ? body.totp : undefined;
  if (!hasTotpFlow && !password) {
    return { kind: 'denied', message: 'Enter your sign-in password to unlock.' };
  }

  try {
    const outcome = hasTotpFlow
      ? await submitKanidmTotp(config, body.pendingId as string, user.username, totp ?? '', fetchImpl)
      : await startKanidmPasswordAuth(config, user.username, password ?? '', fetchImpl);
    if (outcome.kind !== 'success') {
      if (outcome.kind === 'totp-required') {
        return outcome;
      }
      recordFailedLogin(key, Date.now());
      const state = loginAttempts.get(key);
      if (state && state.lockedUntil > Date.now()) {
        return { kind: 'locked-out', retryAfterSeconds: Math.ceil((state.lockedUntil - Date.now()) / 1000) };
      }
      return outcome.kind === 'denied'
        ? { kind: 'denied', message: 'That password or code was not accepted.' }
        : { kind: 'error', message: 'vault identity verification failed' };
    }
    loginAttempts.delete(key);
    const session = mintSession(config, user.username);
    return { kind: 'unlocked', token: session.token, expiresAt: session.expiresAt };
  } catch (caught) {
    return { kind: 'error', message: caught instanceof Error ? caught.message : 'vault identity verification failed' };
  }
};

export const assertVaultUnlocked = (config: AppConfig, headers: IncomingHttpHeaders, user: CurrentUser): void => {
  if (!activeVaultSessionForUser(config, headers, user)) {
    throw new VaultHttpError('vault session required; unlock the vault first', 401);
  }
};

export const vaultSessionExpiresAt = (config: AppConfig, headers: IncomingHttpHeaders): { expiresAt?: number; idleExpiresAt?: number } => {
  const session = lookupVaultSession(config, headers);
  if (!session) {
    return {};
  }
  return { expiresAt: session.expiresAt, idleExpiresAt: session.lastSeenAt + configuredIdleTtlMs(config) };
};
