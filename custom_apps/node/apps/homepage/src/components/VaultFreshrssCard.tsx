import { $, component$, useSignal } from '@builder.io/qwik';
import type { VaultFeature, VaultFreshrssPassword } from '../shared/types.js';
import { copyVaultSecret, vaultRequest } from '../shared/vault-client.js';
import { ExplainMore } from './ExplainMore.js';

export const VaultFreshrssCard = component$(({ feature, username }: { feature: VaultFeature; username: string }) => {
  const confirmGenerate = useSignal(false);
  const generating = useSignal(false);
  const result = useSignal<VaultFreshrssPassword>();
  const error = useSignal('');
  const copiedField = useSignal('');

  const generate = $(async () => {
    generating.value = true;
    error.value = '';
    try {
      const response = await vaultRequest<VaultFreshrssPassword>('POST', '/api/vault/freshrss', {});
      if (response.status === 200 && response.data?.ok) {
        result.value = response.data;
        confirmGenerate.value = false;
        copiedField.value = '';
      } else {
        error.value = response.error ?? response.data?.error ?? 'The API password could not be set.';
      }
    } finally {
      generating.value = false;
    }
  });

  const copy = $(async (field: 'password' | 'url', value: string) => {
    if (await copyVaultSecret(value)) {
      copiedField.value = field;
      window.setTimeout(() => {
        copiedField.value = '';
      }, 2000);
    }
  });

  return (
    <article class="vault-card" id={`vault-${feature.id}`}>
      <header class="vault-card__head">
        <h3>{feature.name}</h3>
        <p>{feature.description}</p>
      </header>
      {!confirmGenerate.value ? (
        <button type="button" class="vault-danger-button" onClick$={() => {
          confirmGenerate.value = true;
        }}>
          {result.value ? 'Replace app password' : 'Create app password'}
        </button>
      ) : (
        <div class="vault-confirm">
          <p>Generate a new FreshRSS app password for <strong>{username}</strong>?</p>
          <button type="button" class="vault-danger-button" disabled={generating.value} onClick$={generate}>
            {generating.value ? 'Generating…' : 'Yes, generate'}
          </button>
          <button type="button" onClick$={() => {
            confirmGenerate.value = false;
          }}>
            Cancel
          </button>
        </div>
      )}
      {error.value && <p class="key-status error">{error.value}</p>}
      {result.value && (
        <div class="vault-once">
          <p>
            <strong>Shown once.</strong> Copy it into your reader app now; the server stores only a hash of this
            password. Regenerate any time if a device is lost.
          </p>
          <dl class="vault-once__fields">
            <div>
              <dt>Username</dt>
              <dd><code>{result.value.username}</code></dd>
            </div>
            <div>
              <dt>API password</dt>
              <dd>
                <code>{result.value.password}</code>
                <button type="button" onClick$={() => copy('password', result.value?.password ?? '')}>
                  {copiedField.value === 'password' ? 'Copied' : 'Copy'}
                </button>
              </dd>
            </div>
            <div>
              <dt>Feed reader address</dt>
              <dd>
                <code>{result.value.greaderUrl}</code>
                <button type="button" onClick$={() => copy('url', result.value?.greaderUrl ?? '')}>
                  {copiedField.value === 'url' ? 'Copied' : 'Copy'}
                </button>
              </dd>
            </div>
          </dl>
          {feature.webUrl && (
            <p class="hint">Feed management stays at <a href={feature.webUrl} target="_blank" rel="noreferrer">{feature.webUrl}</a>.</p>
          )}
        </div>
      )}
      <ExplainMore
        title="FreshRSS app password"
        plain={
          <p>
            Feed reader apps usually cannot use your normal login, so they sign in with your username and this separate
            password instead. The old password stops working the moment you replace it.
          </p>
        }
        technical={
          <p>
            The server generates the password and stores only its hash, so an existing password can never be shown
            again, only replaced. Reader apps connect through the Google Reader API at the address above; generating a
            new password makes any reader still holding the old one ask you to sign in again.
          </p>
        }
      />
    </article>
  );
});
