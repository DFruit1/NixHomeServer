import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { VaultFeature, VaultSshKeyList } from '../shared/types.js';
import { vaultRequest } from '../shared/vault-client.js';

export const VaultSshKeysCard = component$(({ feature }: { feature: VaultFeature }) => {
  const keys = useSignal<string[]>([]);
  const loading = useSignal(true);
  const loadError = useSignal('');
  const keyValue = useSignal('');
  const saveStatus = useSignal('');
  const saveStatusKind = useSignal<'success' | 'error'>('success');
  const saving = useSignal(false);

  const loadKeys = $(async () => {
    const result = await vaultRequest<VaultSshKeyList>('GET', '/api/vault/ssh-keys');
    if (result.status === 200 && result.data?.ok) {
      keys.value = result.data.keys;
      loadError.value = '';
    } else {
      loadError.value = result.error ?? result.data?.error ?? 'Registered keys could not be loaded.';
    }
    loading.value = false;
  });

  useVisibleTask$(() => {
    void loadKeys();
  });

  const save = $(async () => {
    const publicKey = keyValue.value.trim();
    if (!publicKey) {
      saveStatusKind.value = 'error';
      saveStatus.value = 'Paste one OpenSSH public key before saving.';
      return;
    }
    saving.value = true;
    saveStatus.value = '';
    try {
      const result = await vaultRequest<{ ok: boolean; message?: string; details?: string }>('POST', '/api/vault/ssh-keys', { publicKey });
      if (result.status === 200 && result.data?.ok) {
        keyValue.value = '';
        saveStatusKind.value = 'success';
        saveStatus.value = result.data.details
          ? `${result.data.message ?? 'SSH public key saved.'} ${result.data.details}`
          : result.data.message ?? 'SSH public key saved.';
        await loadKeys();
      } else {
        saveStatusKind.value = 'error';
        saveStatus.value = result.error ?? result.data?.error ?? 'The public key could not be saved.';
      }
    } finally {
      saving.value = false;
    }
  });

  return (
    <article class="vault-card" id={`vault-${feature.id}`}>
      <header class="vault-card__head">
        <h2>{feature.name}</h2>
        <p>{feature.description}</p>
      </header>
      <div class="vault-keys-list">
        <h3>Registered device keys</h3>
        {loading.value && <p class="hint">Loading registered keys…</p>}
        {loadError.value && <p class="key-status error">{loadError.value}</p>}
        {!loading.value && !loadError.value && keys.value.length === 0 && (
          <p class="hint">No device keys are registered yet.</p>
        )}
        {keys.value.length > 0 && (
          <ul>
            {keys.value.map((line) => (
              <li key={line}>
                <code>{line}</code>
              </li>
            ))}
          </ul>
        )}
      </div>
      <div class="vault-key-form">
        <label for="vault-ssh-public-key">Add a device key</label>
        <p class="hint">Paste one OpenSSH public key line. Saving adds the key without removing keys for your other devices.</p>
        <textarea
          id="vault-ssh-public-key"
          placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop"
          rows={4}
          value={keyValue.value}
          onInput$={(_, target) => {
            keyValue.value = target.value;
          }}
        />
        <button type="button" disabled={saving.value} onClick$={save}>
          {saving.value ? 'Saving…' : 'Save Public Key'}
        </button>
        {saveStatus.value && <p class={{ 'key-status': true, error: saveStatusKind.value === 'error' }}>{saveStatus.value}</p>}
      </div>
    </article>
  );
});
