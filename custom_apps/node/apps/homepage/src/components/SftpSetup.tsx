import { $, component$, useSignal } from '@builder.io/qwik';
import { sftpKeygenCommands, sftpOsLabels } from '../shared/ui-constants.js';
import type { SftpKeyResponse } from '../shared/types.js';
import { CommandSnippet } from './CommandSnippet.js';
import { SftpAccessDetails } from './SftpAccessDetails.js';

export const SftpSetup = component$(({ username, domain, serverHost }: { username: string; domain: string; serverHost: string }) => {
  const keyStatus = useSignal('');
  const keyStatusKind = useSignal<'success' | 'error'>('success');
  const keySubmitting = useSignal(false);
  const keyValue = useSignal('');

  const savePublicKey = $(async () => {
    const publicKey = keyValue.value.trim();
    if (!publicKey) {
      keyStatusKind.value = 'error';
      keyStatus.value = 'Paste one OpenSSH public key before saving.';
      return;
    }

    keyStatus.value = '';
    keySubmitting.value = true;
    try {
      const response = await fetch('/api/sftp-key', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ publicKey }),
      });
      const body = (await response.json().catch(() => ({}))) as Partial<SftpKeyResponse> & { error?: string };
      if (!response.ok || body.ok === false) {
        throw new Error(body.error || 'Public key could not be saved');
      }
      keyValue.value = '';
      keyStatusKind.value = 'success';
      keyStatus.value = body.details ? `${body.message || 'SFTP public key saved.'} ${body.details}` : body.message || 'SFTP public key saved.';
    } catch (caught) {
      keyStatusKind.value = 'error';
      keyStatus.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      keySubmitting.value = false;
    }
  });

  return (
    <article class="sftp-os-card sftp-setup-card">
      <h2>SSHFS Mount Setup</h2>
      <input class="os-radio" id="sftp-setup-windows" name="sftp-setup-os" type="radio" defaultChecked />
      <input class="os-radio" id="sftp-setup-macos" name="sftp-setup-os" type="radio" />
      <input class="os-radio" id="sftp-setup-linux" name="sftp-setup-os" type="radio" />
      <div class="os-picker" role="tablist" aria-label="Operating system">
        <label role="tab" for="sftp-setup-windows">
          Windows
        </label>
        <label role="tab" for="sftp-setup-macos">
          macOS
        </label>
        <label role="tab" for="sftp-setup-linux">
          Linux
        </label>
      </div>
      <ol class="steps sftp-step-list">
        <li>
          <h3>Install SSHFS</h3>
          <p>Choose your OS above and install the SSHFS client for that device.</p>
          <p class="os-panel windows">Install WinFsp and SSHFS-Win before mounting the server.</p>
          <p class="os-panel macos">Install macFUSE and sshfs before mounting the server.</p>
          <p class="os-panel linux">Install the sshfs package from your Linux distribution.</p>
        </li>
        <li>
          <h3>Generate an SSH key pair</h3>
          <p>Choose your OS above and run the matching command on your device. Use a passphrase if you want extra key protection.</p>
          <CommandSnippet class="os-panel windows" command={sftpKeygenCommands.windows} />
          <CommandSnippet class="os-panel macos" command={sftpKeygenCommands.macos} />
          <CommandSnippet class="os-panel linux" command={sftpKeygenCommands.linux} />
        </li>
        <li>
          <h3>Upload SSHFS Public Key</h3>
          <p>Paste one OpenSSH public key after generating it with the selector above. Saving replaces your current SSHFS key file on the server.</p>
          <div class="sftp-key-form">
            <textarea
              id="sftp-public-key"
              placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop"
              rows={5}
              value={keyValue.value}
              onInput$={(_, target) => {
                keyValue.value = target.value;
              }}
            />
            <button id="save-sftp-key" type="button" disabled={keySubmitting.value} onClick$={savePublicKey}>
              {keySubmitting.value ? 'Saving...' : 'Save Public Key'}
            </button>
            {keyStatus.value && <p class={{ 'key-status': true, error: keyStatusKind.value === 'error' }}>{keyStatus.value}</p>}
          </div>
        </li>
        <li>
          <h3 class="os-panel windows">Mount from {sftpOsLabels.windows}</h3>
          <h3 class="os-panel macos">Mount from {sftpOsLabels.macos}</h3>
          <h3 class="os-panel linux">Mount from {sftpOsLabels.linux}</h3>
          <div class="os-panel windows">
            <SftpAccessDetails os="windows" username={username} serverHost={serverHost} />
          </div>
          <div class="os-panel macos">
            <SftpAccessDetails os="macos" username={username} serverHost={serverHost} />
          </div>
          <div class="os-panel linux">
            <SftpAccessDetails os="linux" username={username} serverHost={serverHost} />
          </div>
        </li>
      </ol>
      <p class="hint">Browser uploads still work at https://files.{domain}; SSHFS is for larger or repeated transfers.</p>
    </article>
  );
});
