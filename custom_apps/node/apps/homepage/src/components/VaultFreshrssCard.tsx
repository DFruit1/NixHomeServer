import { $, component$, useSignal } from '@builder.io/qwik';
import type { VaultFeature, VaultFreshrssPassword } from '../shared/types.js';
import { copyVaultSecret, vaultRequest } from '../shared/vault-client.js';

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
        <button type="button" class="doc-btn" onClick$={() => {
          confirmGenerate.value = true;
        }}>
          {result.value ? 'Replace app password' : 'Create app password'}
        </button>
      ) : (
        <div class="vault-confirm">
          <p>Generate a new FreshRSS app password for <strong>{username}</strong>? Any earlier password stops working straight away.</p>
          <div class="doc-actions">
            <button type="button" class="doc-btn doc-btn--danger" disabled={generating.value} onClick$={generate}>
              {generating.value ? 'Generating…' : 'Yes, generate'}
            </button>
            <button type="button" class="doc-btn doc-btn--quiet" onClick$={() => {
              confirmGenerate.value = false;
            }}>
              Cancel
            </button>
          </div>
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
                <button type="button" class="doc-btn doc-btn--small" onClick$={() => copy('password', result.value?.password ?? '')}>
                  {copiedField.value === 'password' ? 'Copied' : 'Copy'}
                </button>
              </dd>
            </div>
            <div>
              <dt>Feed reader address</dt>
              <dd>
                <code>{result.value.greaderUrl}</code>
                <button type="button" class="doc-btn doc-btn--small" onClick$={() => copy('url', result.value?.greaderUrl ?? '')}>
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
      <details class="doc-more">
        <summary>How it works</summary>
        <p>
          Feed reader apps cannot use your normal sign-in, so they sign in with your username and this separate
          password. The server keeps only a hash of it, so a password can never be shown again, only replaced, and
          replacing it signs out every reader still using the old one.
        </p>
      </details>
    </article>
  );
});
