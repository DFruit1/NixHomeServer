import { randomBytes } from 'node:crypto';
import type { AppConfig } from '../config.js';

const KANIDM_COOKIE_NAME = 'auth-session-id';
const KANIDM_SESSION_HEADER = 'x-kanidm-auth-session-id';
const REQUEST_TIMEOUT_MS = 10_000;
const PENDING_TOTP_TTL_MS = 3 * 60 * 1000;
const MAX_PENDING_FLOWS = 20;

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

type PendingTotp = {
  id: string;
  username: string;
  cookie: string;
  sessionHeader?: string;
  createdAt: number;
  // Retained only until the TOTP challenge completes or this short-lived flow expires.
  password?: string;
};

const pendingTotps = new Map<string, PendingTotp>();

export const mergeCookies = (current: string, additions: string[]): string => {
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
  if (kind === 'choose' && Array.isArray(value) && value.every((item) => typeof item === 'string')) {
    return { kind: 'choose', mechs: value };
  }
  if (kind === 'continue' && Array.isArray(value)) {
    // AuthAllowed also includes structured security-key challenges. Keep the
    // supported string methods even when such an alternative is present.
    return { kind: 'continue', allowed: value.filter((item): item is string => typeof item === 'string') };
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
  // Transport/protocol failures are not incorrect credentials and must not
  // consume the user's failed-password budget.
  if (response.status !== 200 && response.status !== 401) {
    throw new Error('vault identity verification is unavailable');
  }
  const cookies = collectKanidmCookies(response.headers);
  // The value is a signed JWS (mixed-case base64url). Never normalise its
  // case: Kanidm prefers this header over the cookie when resolving the auth
  // session, and a corrupted value makes every following step fail while the
  // intact cookie never gets a chance to rescue the flow.
  const nextSessionHeader = response.headers.get(KANIDM_SESSION_HEADER) ?? undefined;
  let bodyJson: unknown;
  try {
    bodyJson = await response.json();
  } catch {
    bodyJson = undefined;
  }
  return {
    status: response.status,
    state: response.status === 401 ? { kind: 'denied', message: '' } : parseKanidmState(bodyJson),
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
    throw new Error('This account does not offer password sign-in for the vault.');
  }
  const mech = mechs.includes('passwordmfa') ? 'passwordmfa' : 'password';
  cookie = mergeCookies(cookie, init.cookies);
  // Kanidm issues the signed session id on every auth response; carry the
  // init one forward so later steps resolve the session through the header.
  sessionHeader = init.sessionHeader ?? sessionHeader;

  const begin = await postKanidmAuth(fetchImpl, kanidmUrl, { step: { begin: mech } }, cookie, sessionHeader);
  if (begin.state?.kind === 'denied') {
    return { kind: 'denied' };
  }
  if (begin.state?.kind !== 'continue') {
    throw new Error('vault identity verification is unavailable');
  }
  cookie = mergeCookies(cookie, [...init.cookies, ...begin.cookies]);
  sessionHeader = begin.sessionHeader ?? sessionHeader;

  // Kanidm passwordmfa requests TOTP BEFORE the password. Never submit a
  // credential the current challenge does not allow.
  if (begin.state.allowed.includes('totp')) {
    return registerPendingTotp(username, cookie, sessionHeader, password);
  }
  if (!begin.state.allowed.includes('password')) {
    throw new Error('This account requires a sign-in method the vault does not support.');
  }

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
  // Consume before awaiting I/O: concurrent requests must not reuse a flow.
  pendingTotps.delete(pendingId);
  if (Date.now() - pending.createdAt >= PENDING_TOTP_TTL_MS) {
    return { kind: 'denied' };
  }
  const code = totp.trim();
  if (!/^\d{6}$/.test(code)) {
    return { kind: 'denied' };
  }
  let cred = await postKanidmAuth(
    fetchImpl,
    kanidmUrl,
    { step: { cred: { totp: Number.parseInt(code, 10) } } },
    pending.cookie,
    pending.sessionHeader,
  );
  let cookie = mergeCookies(pending.cookie, cred.cookies);
  const sessionHeader = cred.sessionHeader ?? pending.sessionHeader;
  if (cred.state?.kind === 'continue' && cred.state.allowed.includes('password') && pending.password !== undefined) {
    cred = await postKanidmAuth(
      fetchImpl, kanidmUrl, { step: { cred: { password: pending.password } } }, cookie, sessionHeader,
    );
    cookie = mergeCookies(cookie, cred.cookies);
  }
  if (cred.state?.kind === 'denied') {
    return { kind: 'denied' };
  }
  if (cred.state?.kind !== 'success') {
    throw new Error('vault identity verification is unavailable');
  }
  await revokeKanidmSession(fetchImpl, kanidmUrl, cred.state.token, cookie);
  return { kind: 'success' };
};

const registerPendingTotp = (username: string, cookie: string, sessionHeader?: string, password?: string): KanidmAuthOutcome => {
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
    password,
    createdAt: now,
  };
  pendingTotps.set(pending.id, pending);
  return { kind: 'totp-required', pendingId: pending.id };
};

export const prunePendingTotpFlows = (now: number): void => {
  for (const [id, pending] of pendingTotps) {
    if (now - pending.createdAt > PENDING_TOTP_TTL_MS) {
      pendingTotps.delete(id);
    }
  }
};
