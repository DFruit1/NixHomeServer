import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { VaultFeature, VaultSyncthingKey } from '../shared/types.js';
import { copyVaultSecret, vaultRequest } from '../shared/vault-client.js';
import { ExplainMore } from './ExplainMore.js';

export const VaultSyncthingCard = component$(({ feature }: { feature: VaultFeature }) => {
  const apiKey = useSignal('');
  const revealed = useSignal(false);
  const loading = useSignal(true);
  const loadError = useSignal('');
  const confirmRotate = useSignal(false);
  const rotating = useSignal(false);
  const actionError = useSignal('');
  const copied = useSignal(false);

  const load = $(async () => {
    const result = await vaultRequest<VaultSyncthingKey>('GET', '/api/vault/syncthing');
    if (result.status === 200 && result.data?.ok) {
      apiKey.value = result.data.apiKey ?? '';
      loadError.value = '';
    } else {
      loadError.value = result.error ?? result.data?.error ?? 'The API key could not be loaded.';
    }
    loading.value = false;
  });

  useVisibleTask$(() => {
    void load();
  });

  const rotate = $(async () => {
    rotating.value = true;
    actionError.value = '';
    try {
      const result = await vaultRequest<VaultSyncthingKey>('POST', '/api/vault/syncthing', {});
      if (result.status === 200 && result.data?.ok) {
        apiKey.value = result.data.apiKey ?? '';
        revealed.value = true;
        confirmRotate.value = false;
        copied.value = false;
      } else {
        actionError.value = result.error ?? result.data?.error ?? 'The API key could not be regenerated.';
      }
    } finally {
      rotating.value = false;
    }
  });

  const copy = $(async () => {
    if (await copyVaultSecret(apiKey.value)) {
      copied.value = true;
      window.setTimeout(() => {
        copied.value = false;
      }, 2000);
    }
  });

  return (
    <article class="vault-card" id={`vault-${feature.id}`}>
      <header class="vault-card__head">
        <h3>{feature.name}</h3>
        <p>{feature.description}</p>
      </header>
      {loading.value && <p class="hint">Loading the key…</p>}
      {loadError.value && <p class="key-status error">{loadError.value}</p>}
      {!loading.value && !loadError.value && (
        <>
          <div class="vault-secret">
            {revealed.value ? (
              <code class="vault-secret__value">{apiKey.value}</code>
            ) : (
              <code class="vault-secret__value vault-secret__value--hidden" aria-label="API key is hidden">
                {'•'.repeat(24)}
              </code>
            )}
            <div class="vault-secret__actions">
              <button type="button" onClick$={() => {
                revealed.value = !revealed.value;
              }}>
                {revealed.value ? 'Hide' : 'Reveal'}
              </button>
              <button type="button" onClick$={copy}>
                {copied.value ? 'Copied' : 'Copy'}
              </button>
            </div>
          </div>
          {!confirmRotate.value ? (
            <button type="button" class="vault-danger-button" onClick$={() => {
              confirmRotate.value = true;
            }}>
              Regenerate API key
            </button>
          ) : (
            <div class="vault-confirm">
              <p>
                Regenerate now? Syncthing restarts, the current key stops working immediately, and every script or
                client using it must be updated with the new key.
              </p>
              <button type="button" class="vault-danger-button" disabled={rotating.value} onClick$={rotate}>
                {rotating.value ? 'Regenerating…' : 'Yes, regenerate'}
              </button>
              <button type="button" onClick$={() => {
                confirmRotate.value = false;
              }}>
                Cancel
              </button>
            </div>
          )}
          {actionError.value && <p class="key-status error">{actionError.value}</p>}
        </>
      )}
      <ExplainMore
        title="Syncthing key"
        plain={
          <p>
            Syncthing uses this key so other devices and scripts can control it without your password. Treat it like a
            password and keep it out of shared chats or notes.
          </p>
        }
        technical={
          <p>
            This is the Syncthing REST API key stored in <code>config.xml</code>. Regenerating it restarts Syncthing and
            immediately invalidates every external script or client holding the old value. Server-side automation reads
            the key from Syncthing's own configuration, so it is unaffected.
          </p>
        }
      />
    </article>
  );
});
