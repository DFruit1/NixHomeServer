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
        <h2>{feature.name}</h2>
        <p>{feature.description}</p>
      </header>
      <aside class="guide-callout neutral">
        Feed reader apps sign in to the Google Reader API with your username and this API password instead of your
        Kanidm sign-in. The server cannot show an existing API password, only replace it. Generating a new password
        makes readers holding the old password ask you to sign in again.
      </aside>
      {!confirmGenerate.value ? (
        <button type="button" class="vault-danger-button" onClick$={() => {
          confirmGenerate.value = true;
        }}>
          {result.value ? 'Generate a new API password' : 'Register an API password'}
        </button>
      ) : (
        <div class="vault-confirm">
          <p>Generate a new FreshRSS API password for <strong>{username}</strong>?</p>
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
              <dt>Google Reader API address</dt>
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
    </article>
  );
});
