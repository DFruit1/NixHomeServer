import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { KavitaAuthKey, VaultFeature, VaultKavitaKeys } from '../shared/types.js';
import { copyVaultSecret, vaultRequest } from '../shared/vault-client.js';
import { ExplainMore } from './ExplainMore.js';

const keyLine = (key: KavitaAuthKey): string =>
  [key.name, key.createdAtUtc ? `created ${key.createdAtUtc.slice(0, 10)}` : '', key.lastAccessedAtUtc ? `used ${key.lastAccessedAtUtc.slice(0, 10)}` : '']
    .filter(Boolean)
    .join(' · ');

export const VaultKavitaCard = component$(({ feature, username }: { feature: VaultFeature; username: string }) => {
  const keys = useSignal<KavitaAuthKey[]>([]);
  const opdsUrl = useSignal('');
  const loading = useSignal(true);
  const loadError = useSignal('');
  const newName = useSignal('');
  const busy = useSignal(false);
  const actionError = useSignal('');
  const actionStatus = useSignal('');
  const confirmDeleteId = useSignal(0);
  const confirmRotateId = useSignal(0);
  const revealedId = useSignal(0);
  const copiedId = useSignal(0);

  const load = $(async () => {
    const result = await vaultRequest<VaultKavitaKeys>('GET', '/api/vault/kavita');
    if (result.status === 200 && result.data?.ok) {
      keys.value = result.data.keys;
      opdsUrl.value = result.data.opdsUrl ?? '';
      loadError.value = '';
    } else {
      loadError.value = result.error ?? result.data?.error ?? 'API keys could not be loaded.';
    }
    loading.value = false;
  });

  useVisibleTask$(() => {
    void load();
  });

  const mutate = $(async (payload: { action: string; name?: string; authKeyId?: number }, successMessage: string) => {
    busy.value = true;
    actionError.value = '';
    actionStatus.value = '';
    try {
      const result = await vaultRequest<{ ok: boolean }>('POST', '/api/vault/kavita', payload);
      if (result.status === 200 && result.data?.ok) {
        actionStatus.value = successMessage;
        confirmDeleteId.value = 0;
        confirmRotateId.value = 0;
        await load();
      } else {
        actionError.value = result.error ?? result.data?.error ?? 'The API key change failed.';
      }
    } finally {
      busy.value = false;
    }
  });

  const copyKey = $(async (key: KavitaAuthKey) => {
    if (await copyVaultSecret(key.key)) {
      copiedId.value = key.id;
      window.setTimeout(() => {
        copiedId.value = 0;
      }, 2000);
    }
  });

  return (
    <article class="vault-card" id={`vault-${feature.id}`}>
      <header class="vault-card__head">
        <h3>{feature.name}</h3>
        <p>{feature.description}</p>
      </header>
      {loading.value && <p class="hint">Loading keys…</p>}
      {loadError.value && <p class="key-status error">{loadError.value}</p>}
      {!loading.value && !loadError.value && (
        <>
          {opdsUrl.value && (
            <div class="vault-opds">
              <h3>OPDS catalogue address</h3>
              <code>{opdsUrl.value}</code>
            </div>
          )}
          <ul class="vault-kavita-keys">
            {keys.value.map((key) => (
              <li key={key.id} class="vault-kavita-key">
                <div class="vault-kavita-key__head">
                  <strong>{key.name}</strong>
                  <small>{keyLine(key)}</small>
                </div>
                <code class={{ 'vault-secret__value': true, 'vault-secret__value--hidden': revealedId.value !== key.id }}>
                  {revealedId.value === key.id ? key.key : '••••••••'}
                </code>
                <div class="vault-secret__actions">
                  <button type="button" onClick$={() => {
                    revealedId.value = revealedId.value === key.id ? 0 : key.id;
                  }}>
                    {revealedId.value === key.id ? 'Hide' : 'Reveal'}
                  </button>
                  <button type="button" onClick$={() => copyKey(key)}>
                    {copiedId.value === key.id ? 'Copied' : 'Copy'}
                  </button>
                  {confirmRotateId.value === key.id ? (
                    <>
                      <button
                        type="button"
                        class="vault-danger-button"
                        disabled={busy.value}
                        onClick$={() => mutate({ action: 'rotate', authKeyId: key.id }, `Key ${key.name} regenerated.`)}
                      >
                        Confirm rotate
                      </button>
                      <button type="button" onClick$={() => {
                        confirmRotateId.value = 0;
                      }}>
                        Cancel
                      </button>
                    </>
                  ) : (
                    <button type="button" disabled={busy.value} onClick$={() => {
                      confirmRotateId.value = key.id;
                      confirmDeleteId.value = 0;
                    }}>
                      Regenerate
                    </button>
                  )}
                  {confirmDeleteId.value === key.id ? (
                    <>
                      <button
                        type="button"
                        class="vault-danger-button"
                        disabled={busy.value}
                        onClick$={() => mutate({ action: 'delete', authKeyId: key.id }, `Key ${key.name} deleted.`)}
                      >
                        Confirm delete
                      </button>
                      <button type="button" onClick$={() => {
                        confirmDeleteId.value = 0;
                      }}>
                        Cancel
                      </button>
                    </>
                  ) : (
                    <button type="button" disabled={busy.value} onClick$={() => {
                      confirmDeleteId.value = key.id;
                      confirmRotateId.value = 0;
                    }}>
                      Delete
                    </button>
                  )}
                </div>
              </li>
            ))}
            {keys.value.length === 0 && <li class="hint">No API keys exist for your Kavita account yet.</li>}
          </ul>
          <div class="vault-key-form">
            <label for="vault-kavita-name">Register a new key</label>
            <div class="vault-inline-form">
              <input
                id="vault-kavita-name"
                type="text"
                placeholder="For example: Tablet reader"
                maxLength={64}
                value={newName.value}
                onInput$={(_, target) => {
                  newName.value = target.value;
                }}
              />
              <button
                type="button"
                disabled={busy.value || !newName.value.trim()}
                onClick$={() => mutate({ action: 'create', name: newName.value.trim() }, `Key ${newName.value.trim()} created.`)}
              >
                {busy.value ? 'Working…' : 'Create key'}
              </button>
            </div>
          </div>
          {actionStatus.value && <p class="key-status">{actionStatus.value}</p>}
          {actionError.value && <p class="key-status error">{actionError.value}</p>}
        </>
      )}
      <ExplainMore
        title="Kavita keys"
        plain={
          <p>
            Kavita uses these keys so reading apps can sign in as {username} without your normal password. Give each
            device its own key so you can retire one without affecting the others.
          </p>
        }
        technical={
          <p>
            These are per-user Kavita API keys. OPDS reading apps also need the catalogue address above. Regenerating a
            key invalidates its previous value immediately, and deleting a key stops it working at once.
          </p>
        }
      />
    </article>
  );
});
