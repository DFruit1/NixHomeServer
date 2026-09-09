import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import type { CurrentUser } from '../shared/types.js';
import { mintSession, startSweeper, vaultConfigOrUndefined, activeVaultSessionForUser } from './vault/session-store.js';
import {
  clearFailedLogins,
  loginLockedRemainingMs,
  recordFailedLogin,
  remoteAddressOf,
  remoteAttemptKey,
} from './vault/lockout.js';
import {
  startKanidmPasswordAuth,
  submitKanidmTotp,
  type FetchLike,
} from './vault/kanidm-auth.js';


export { VAULT_COOKIE_NAME } from './vault/session-store.js';
export type { FetchLike } from './vault/kanidm-auth.js';

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

export {
  activeVaultSessionForUser,
  clearVaultSessionCookie,
  endVaultSession,
  getVaultSessionFromRequest,
  getVaultSessionToken,
  lookupVaultSession,
  mintSession,
  pruneVaultState,
  setVaultSessionCookie,
  vaultConfigOrUndefined,
  vaultSessionExpiresAt,
} from './vault/session-store.js';
export { pruneExpiredLockouts } from './vault/lockout.js';
export {
  prunePendingTotpFlows,
  startKanidmPasswordAuth,
  submitKanidmTotp,
} from './vault/kanidm-auth.js';

const passwordRuleOk = (password: unknown): password is string =>
  typeof password === 'string' && password.length >= 1 && password.length <= 1024;

export const attemptVaultUnlock = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  user: CurrentUser,
  body: { password?: unknown; totp?: unknown; pendingId?: unknown },
  fetchImpl?: FetchLike,
): Promise<VaultUnlockOutcome> => {
  startSweeper(config);
  const vault = vaultConfigOrUndefined(config);
  if (!vault) {
    return { kind: 'error', message: 'vault is not enabled' };
  }
  const remoteKey = remoteAttemptKey(user.username, remoteAddressOf(headers));
  const now = Date.now();
  const remainingMs = loginLockedRemainingMs(user.username, remoteKey, now);
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
      recordFailedLogin(user.username, remoteKey, Date.now());
      const state = loginLockedRemainingMs(user.username, remoteKey, Date.now());
      if (state > 0) {
        return { kind: 'locked-out', retryAfterSeconds: Math.ceil(state / 1000) };
      }
      return outcome.kind === 'denied'
        ? { kind: 'denied', message: 'That password or code was not accepted.' }
        : { kind: 'error', message: 'vault identity verification failed' };
    }
    clearFailedLogins(user.username, remoteKey);
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
