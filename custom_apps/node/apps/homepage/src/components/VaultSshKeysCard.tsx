import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { VaultFeature, VaultSshKeyList } from '../shared/types.js';
import { copyVaultSecret, vaultRequest } from '../shared/vault-client.js';
import { generateEd25519SshKey, type GeneratedSshKey } from '../shared/ssh-keygen.js';
import { ExplainMore } from './ExplainMore.js';

const fileNameFor = (comment: string): string => {
  const sanitised = comment.trim().replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  return `${sanitised || 'nixhomeserver'}_ed25519`;
};

export const VaultSshKeysCard = component$(({ feature }: { feature: VaultFeature }) => {
  const keys = useSignal<string[]>([]);
  const loading = useSignal(true);
  const loadError = useSignal('');
  const keyValue = useSignal('');
  const saveStatus = useSignal('');
  const saveStatusKind = useSignal<'success' | 'error'>('success');
  const saving = useSignal(false);

  const deviceName = useSignal('');
  const generating = useSignal(false);
  const generateError = useSignal('');
  const generatedKey = useSignal<GeneratedSshKey>();
  const generatedFileName = useSignal('nixhomeserver_ed25519');
  const copiedPublic = useSignal(false);

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
        saveStatus.value = result.data.message ?? 'Public key saved.';
        await loadKeys();
      } else {
        saveStatusKind.value = 'error';
        saveStatus.value = result.error ?? result.data?.error ?? 'The public key could not be saved.';
      }
    } finally {
      saving.value = false;
    }
  });

  const generate = $(async () => {
    generating.value = true;
    generateError.value = '';
    generatedKey.value = undefined;
    try {
      const comment = deviceName.value.trim() || 'nixhomeserver';
      const key = await generateEd25519SshKey(comment);
      const result = await vaultRequest<{ ok: boolean }>('POST', '/api/vault/ssh-keys', { publicKey: key.publicKey });
      if (result.status !== 200 || !result.data?.ok) {
        generateError.value = result.error ?? result.data?.error ?? 'The new key could not be added to the server.';
        return;
      }
      generatedFileName.value = fileNameFor(comment);
      generatedKey.value = key;
      copiedPublic.value = false;
      deviceName.value = '';
      saveStatus.value = '';
      await loadKeys();
    } catch (error) {
      generateError.value = error instanceof Error ? error.message : 'The key could not be generated.';
    } finally {
      generating.value = false;
    }
  });

  const downloadPrivateKey = $((key: GeneratedSshKey) => {
    const blob = new Blob([key.privateKey], { type: 'application/octet-stream' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = generatedFileName.value;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  });

  const copyPublicKey = $(async (key: GeneratedSshKey) => {
    if (await copyVaultSecret(key.publicKey)) {
      copiedPublic.value = true;
      window.setTimeout(() => {
        copiedPublic.value = false;
      }, 2000);
    }
  });

  return (
    <article class="vault-card" id={`vault-${feature.id}`}>
      <header class="vault-card__head">
        <h3>{feature.name}</h3>
        <p>{feature.description}</p>
      </header>

      <div class="vault-keys-list">
        <h4>Registered device keys</h4>
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
        <h4>Add a key for this device</h4>
        <p class="hint">
          A key is like a password your device supplies automatically, so you never type it. The server only receives
          the public half; the private half stays on your device.
        </p>
        <label for="vault-ssh-device-name">Device name (optional)</label>
        <div class="vault-inline-form">
          <input
            id="vault-ssh-device-name"
            type="text"
            placeholder="For example: My laptop"
            maxLength={64}
            value={deviceName.value}
            onInput$={(_, target) => {
              deviceName.value = target.value;
            }}
          />
          <button type="button" disabled={generating.value} onClick$={generate}>
            {generating.value ? 'Generating…' : 'Generate a key pair'}
          </button>
        </div>
        {generateError.value && <p class="key-status error">{generateError.value}</p>}

        {generatedKey.value && (
          <div class="vault-once">
            <p>
              <strong>Save your private key now.</strong> It is shown only once. Store the downloaded file on the device
              you are setting up, never on the server. The public half has already been added to your account.
            </p>
            <dl class="vault-once__fields">
              <div>
                <dt>Private key file</dt>
                <dd>
                  <code>{generatedFileName.value}</code>
                  <button type="button" onClick$={() => downloadPrivateKey(generatedKey.value!)}>
                    Download
                  </button>
                </dd>
              </div>
              <div>
                <dt>Public key (already added)</dt>
                <dd>
                  <code>{generatedKey.value.publicKey}</code>
                  <button type="button" onClick$={() => copyPublicKey(generatedKey.value!)}>
                    {copiedPublic.value ? 'Copied' : 'Copy'}
                  </button>
                </dd>
              </div>
              <div>
                <dt>Fingerprint</dt>
                <dd>
                  <code>{generatedKey.value.fingerprint}</code>
                </dd>
              </div>
            </dl>
            <p class="hint">
              Protect this file like a password. If it is lost, generate a new key pair; an administrator can retire the
              old key.
            </p>
          </div>
        )}

        <details class="vault-manual-key">
          <summary>I already have a key to paste</summary>
          <label for="vault-ssh-public-key">OpenSSH public key</label>
          <p class="hint">
            Paste the contents of a <code>.pub</code> file, such as <code>id_ed25519.pub</code>. It starts with the key
            type, for example <code>ssh-ed25519</code>. Saving adds the key without removing keys for your other
            devices.
          </p>
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
        </details>
      </div>

      <ExplainMore
        title="SFTP and SSHFS keys"
        plain={
          <p>
            A key pair is two matched files: a public key you can share and a private key you keep. The server only
            needs the public key, and your device proves who it is with the private key. Nothing secret is ever sent to
            the server or typed in.
          </p>
        }
        technical={
          <div>
            <p>
              This page generates an Ed25519 key pair in your browser using the Web Crypto API. Only the public line
              (<code>ssh-ed25519 AAAA…</code>) is sent to the server and appended to your authorized-keys file. The
              private key never leaves the device.
            </p>
            <p>
              Each device should use its own key with a descriptive comment so the fingerprints above stay
              distinguishable. Up to 10 keys can be registered. To replace a lost device, generate a new key, then ask
              an administrator to retire the old one.
            </p>
          </div>
        }
      />
    </article>
  );
});
