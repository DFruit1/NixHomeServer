import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { PropFunction } from '@builder.io/qwik';
import type { VaultUnlockResponse } from '../shared/types.js';
import { vaultRequest } from '../shared/vault-client.js';

export const VaultGate = component$(({
  unlocked,
  expiresAt,
  idleExpiresAt,
  sessionTtlSeconds,
  idleTtlSeconds,
  onRefresh,
}: {
  unlocked: boolean;
  expiresAt?: string;
  idleExpiresAt?: string;
  sessionTtlSeconds?: number;
  idleTtlSeconds?: number;
  onRefresh: PropFunction<() => Promise<void>>;
}) => {
  const password = useSignal('');
  const totp = useSignal('');
  const pendingId = useSignal('');
  const totpRequired = useSignal(false);
  const error = useSignal('');
  const errorKind = useSignal<'error' | 'success'>('error');
  const busy = useSignal(false);
  const remainingSeconds = useSignal<number | null>(null);

  useVisibleTask$(({ track, cleanup }) => {
    const active = track(() => unlocked);
    const absolute = track(() => expiresAt);
    const idle = track(() => idleExpiresAt);
    if (!active) {
      remainingSeconds.value = null;
      return;
    }
    const targets = [absolute, idle].filter((value): value is string => Boolean(value));
    if (targets.length === 0) {
      remainingSeconds.value = null;
      return;
    }
    const target = Math.min(...targets.map((value) => Date.parse(value)));
    const tick = () => {
      const left = Math.round((target - Date.now()) / 1000);
      if (left <= 0) {
        remainingSeconds.value = 0;
        void onRefresh();
        return;
      }
      remainingSeconds.value = left;
    };
    tick();
    const timer = window.setInterval(tick, 1000);
    cleanup(() => window.clearInterval(timer));
  });

  const submit = $(async () => {
    if (busy.value) {
      return;
    }
    busy.value = true;
    error.value = '';
    try {
      const body = pendingId.value
        ? { pendingId: pendingId.value, totp: totp.value.trim() }
        : { password: password.value };
      const result = await vaultRequest<VaultUnlockResponse>('POST', '/api/vault/session', body);
      if (result.status === 429) {
        errorKind.value = 'error';
        error.value = result.data?.error ?? 'Too many failed attempts. Try again later.';
        return;
      }
      if (result.data?.totpRequired) {
        pendingId.value = result.data.pendingId ?? '';
        totpRequired.value = true;
        error.value = '';
        return;
      }
      if (!result.data?.ok) {
        pendingId.value = '';
        totpRequired.value = false;
        totp.value = '';
        errorKind.value = 'error';
        error.value = result.data?.error ?? 'Sign-in failed.';
        return;
      }
      password.value = '';
      totp.value = '';
      pendingId.value = '';
      totpRequired.value = false;
      error.value = '';
      await onRefresh();
    } catch {
      errorKind.value = 'error';
      error.value = 'The unlock request could not be sent.';
    } finally {
      busy.value = false;
    }
  });

  const lock = $(async () => {
    await vaultRequest('DELETE', '/api/vault/session', {});
    await onRefresh();
  });

  const lockLabel = (seconds: number | null): string => {
    if (seconds === null) {
      return 'Unlocked';
    }
    if (seconds <= 0) {
      return 'Locking…';
    }
    if (seconds < 60) {
      return `Locks in ${seconds}s`;
    }
    const minutes = Math.ceil(seconds / 60);
    return `Locks in ${minutes} min`;
  };

  return (
    <section class={{ 'vault-gate': true, 'vault-gate--open': unlocked }} aria-label="Keys and secrets unlock">
      <header class="vault-gate__brand">
        <img class="vault-gate__logo" src="/logos/kanidm.svg" alt="" width={44} height={44} />
        <div class="vault-gate__brand-text">
          <span class="vault-gate__provider">Kanidm account</span>
          <h2>{unlocked ? 'Keys and secrets unlocked' : 'Unlock keys and secrets'}</h2>
        </div>
        <span
          class={{ 'vault-status': true, 'vault-status--open': unlocked }}
          role="status"
          aria-label={unlocked ? 'Status: unlocked' : 'Status: locked'}
        >
          {unlocked ? (
            <svg class="vault-status__icon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="5" y="11" width="14" height="10" rx="2" />
              <path d="M8 11V7a4 4 0 0 1 7.5-2" />
            </svg>
          ) : (
            <svg class="vault-status__icon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="5" y="11" width="14" height="10" rx="2" />
              <path d="M8 11V7a4 4 0 0 1 8 0v4" />
            </svg>
          )}
          {unlocked ? 'Unlocked' : 'Locked'}
        </span>
      </header>

      {!unlocked ? (
        <form
          class="vault-unlock"
          preventdefault:submit
          onSubmit$={submit}
        >
          <p>
            These settings can create and replace the credentials that apps use to reach your server. To keep them safe,
            confirm it is really you with a second sign-in. The unlock lasts{' '}
            {Math.round((sessionTtlSeconds ?? 900) / 60)} minutes, or {Math.round((idleTtlSeconds ?? 300) / 60)} minutes
            after your last action, and ends when you close the browser.
          </p>
          {!totpRequired.value ? (
            <>
              <label class="vault-field" for="vault-password">
                Kanidm password for your account
              </label>
              <input
                id="vault-password"
                type="password"
                autoComplete="current-password"
                placeholder="Kanidm password"
                value={password.value}
                onInput$={(_, target) => {
                  password.value = target.value;
                }}
              />
            </>
          ) : (
            <>
              <p class="vault-unlock__hint">Your account uses sign-in codes. Enter the six-digit code from your authenticator app.</p>
              <label class="vault-field" for="vault-totp">
                Six-digit sign-in code
              </label>
              <input
                id="vault-totp"
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="123456"
                value={totp.value}
                onInput$={(_, target) => {
                  totp.value = target.value;
                }}
              />
            </>
          )}
          <button id="vault-unlock-submit" type="submit" disabled={busy.value}>
            {busy.value ? 'Checking…' : totpRequired.value ? 'Finish unlock' : 'Unlock'}
          </button>
          {error.value && <p class={{ 'key-status': true, error: errorKind.value === 'error' }}>{error.value}</p>}
        </form>
      ) : (
        <div class="vault-unlock vault-unlock--open">
          <p>
            <strong>Unlocked.</strong> Changes you make here apply immediately.{' '}
            <span class="vault-countdown">{lockLabel(remainingSeconds.value)}</span>
          </p>
          <button type="button" class="vault-lock-button" onClick$={lock}>
            Lock now
          </button>
        </div>
      )}
    </section>
  );
});
