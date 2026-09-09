import { randomBytes } from 'node:crypto';
import type { IncomingHttpHeaders, ServerResponse } from 'node:http';
import type { AppConfig } from '../config.js';
import type { CurrentUser } from '../../shared/types.js';
import { pruneExpiredLockouts } from './lockout.js';
import { prunePendingTotpFlows } from './kanidm-auth.js';

export const VAULT_COOKIE_NAME = 'homepage-vault-session';
const VAULT_COOKIE_PATH = '/api/vault';
const MAX_SESSIONS_PER_USER = 5;
const MAX_SESSIONS_TOTAL = 200;

type VaultSession = {
  token: string;
  username: string;
  createdAt: number;
  expiresAt: number;
  lastSeenAt: number;
};

const sessions = new Map<string, VaultSession>();

let sweeperStarted = false;
let sweeperIdleTtlMs = 5 * 60 * 1000;

export const startSweeper = (config?: AppConfig): void => {
  if (config) {
    sweeperIdleTtlMs = configuredIdleTtlMs(config);
  }
  if (sweeperStarted) {
    return;
  }
  sweeperStarted = true;
  const timer = setInterval(() => {
    const now = Date.now();
    for (const [token, session] of sessions) {
      if (now >= session.expiresAt || now - session.lastSeenAt > sweeperIdleTtlMs) {
        sessions.delete(token);
      }
    }
    prunePendingTotpFlows(now);
    pruneExpiredLockouts(now);
  }, 60_000);
  timer.unref?.();
};

export const vaultConfigOrUndefined = (config: AppConfig) => (config.homepage.vault?.enabled ? config.homepage.vault : undefined);

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
  prunePendingTotpFlows(now);
  pruneExpiredLockouts(now);
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
  startSweeper(config);
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

export const mintSession = (config: AppConfig, username: string): VaultSession => {
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

export const vaultSessionExpiresAt = (config: AppConfig, headers: IncomingHttpHeaders): { expiresAt?: number; idleExpiresAt?: number } => {
  const session = lookupVaultSession(config, headers);
  if (!session) {
    return {};
  }
  return { expiresAt: session.expiresAt, idleExpiresAt: session.lastSeenAt + configuredIdleTtlMs(config) };
};
