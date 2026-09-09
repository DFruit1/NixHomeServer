import type { IncomingHttpHeaders } from 'node:http';

const MAX_FAILED_ATTEMPTS = 5;
const MAX_FAILED_ATTEMPTS_PER_USER = 20;
const LOCKOUT_DURATION_MS = 5 * 60 * 1000;
const LOCKOUT_STATE_TTL_MS = 15 * 60 * 1000;

type LoginAttemptState = {
  failures: number;
  lockedUntil: number;
  updatedAt: number;
};

const remoteAttempts = new Map<string, LoginAttemptState>();
const userAttempts = new Map<string, LoginAttemptState>();

export const remoteAttemptKey = (username: string, remoteAddress: string): string => `${username}|${remoteAddress}`;

export const remoteAddressOf = (headers: IncomingHttpHeaders): string => {
  const forwarded = headers['x-forwarded-for'];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  const candidate = (first ?? '').split(',', 1)[0]?.trim();
  return candidate || 'unknown';
};

const remainingLockMs = (attempts: Map<string, LoginAttemptState>, key: string, now: number): number => {
  const state = attempts.get(key);
  if (!state) {
    return 0;
  }
  if (now < state.lockedUntil) {
    return state.lockedUntil - now;
  }
  if (now - state.updatedAt > LOCKOUT_STATE_TTL_MS) {
    attempts.delete(key);
  }
  return 0;
};

// Per (user, source address) the threshold is tight; a second, looser
// per-username counter means rotating source addresses cannot mint an
// unlimited number of attempts against one account.
export const loginLockedRemainingMs = (username: string, remoteKey: string, now: number): number =>
  Math.max(
    remainingLockMs(remoteAttempts, remoteKey, now),
    remainingLockMs(userAttempts, username, now),
  );

export const recordFailedLogin = (username: string, remoteKey: string, now: number): void => {
  const bump = (attempts: Map<string, LoginAttemptState>, key: string, threshold: number): void => {
    const state = attempts.get(key) ?? { failures: 0, lockedUntil: 0, updatedAt: now };
    state.failures += 1;
    state.updatedAt = now;
    if (state.failures >= threshold) {
      state.lockedUntil = now + LOCKOUT_DURATION_MS;
      state.failures = 0;
    }
    attempts.set(key, state);
  };
  bump(remoteAttempts, remoteKey, MAX_FAILED_ATTEMPTS);
  bump(userAttempts, username, MAX_FAILED_ATTEMPTS_PER_USER);
};

export const clearFailedLogins = (username: string, remoteKey: string): void => {
  remoteAttempts.delete(remoteKey);
  userAttempts.delete(username);
};

export const pruneExpiredLockouts = (now: number): void => {
  for (const attempts of [remoteAttempts, userAttempts]) {
    for (const [key, state] of attempts) {
      if (now - state.updatedAt > LOCKOUT_STATE_TTL_MS && now >= state.lockedUntil) {
        attempts.delete(key);
      }
    }
  }
};
