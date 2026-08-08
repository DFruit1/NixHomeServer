import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { detectClientOs, sftpKeygenCommands, sftpOsLabels } from '../shared/ui-constants.js';
import type { SftpAccess, SftpKeyResponse } from '../shared/types.js';
import { CommandSnippet } from './CommandSnippet.js';
import { SftpAccessDetails } from './SftpAccessDetails.js';

export const SftpSetup = component$(({
  username,
  domain,
  sftp,
  filesWebAvailable,
}: {
  username: string;
  domain: string;
  sftp: SftpAccess;
  filesWebAvailable: boolean;
}) => {
  const keyStatus = useSignal('');
  const keyStatusKind = useSignal<'success' | 'error'>('success');
  const keySubmitting = useSignal(false);
  const keyValue = useSignal('');

  const osRadio = {
    windows: 'sftp-setup-windows',
    macos: 'sftp-setup-macos',
    linux: 'sftp-setup-linux',
  } as const;

  useVisibleTask$(() => {
    const detected = detectClientOs();
    const input = document.getElementById(osRadio[detected]) as HTMLInputElement | null;
    if (input) input.checked = true;
  });

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
    <article id="sshfs-setup" class="sftp-os-card sftp-setup-card">
      <h2>SSHFS Mount Setup</h2>
      <p>Use these steps on the computer you want to connect. For permissions, folder behavior, security, and troubleshooting, <Link href="/uploads?guide=sshfs#guide-detail">read the detailed SSHFS guide</Link>.</p>
      <aside class="guide-callout neutral"><strong>Network:</strong> {sftp.networkNote} Connect to <code>{sftp.host}:{sftp.port}</code>.</aside>
      {sftp.accessNotes.map((note) => (
        <aside class="guide-callout neutral" key={note}>{note}</aside>
      ))}
      <input class="os-radio" id={osRadio.windows} name="sftp-setup-os" type="radio" defaultChecked />
      <input class="os-radio" id={osRadio.macos} name="sftp-setup-os" type="radio" />
      <input class="os-radio" id={osRadio.linux} name="sftp-setup-os" type="radio" />
      <div class="os-picker" role="tablist" aria-label="Operating system">
        <label role="tab" for={osRadio.windows}>
          Windows
        </label>
        <label role="tab" for={osRadio.macos}>
          macOS
        </label>
        <label role="tab" for={osRadio.linux}>
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
          <p>Choose your OS above and run the matching command on your device. Press Enter to leave the passphrase empty when it asks: this keeps automatic mounts simple, because a passphrase-protected key cannot unlock without an interactive prompt. If you want to prevent someone with access to your device from using the key without permission, keep it in an SSH keyring instead of as a plain file on disk — KeePassXC's SSH Agent or an alternative SSH keyring, such as your operating system's built-in SSH agent or keychain.</p>
          <p class="os-panel windows">SSHFS-Win key mode uses <code>~/.ssh/id_rsa</code>. If that file already exists, stop rather than overwrite it and ask an administrator for help choosing a compatible dedicated key.</p>
          <CommandSnippet class="os-panel windows" command={sftpKeygenCommands.windows} />
          <CommandSnippet class="os-panel macos" command={sftpKeygenCommands.macos} />
          <CommandSnippet class="os-panel linux" command={sftpKeygenCommands.linux} />
        </li>
        <li>
          <h3>Upload SSHFS Public Key</h3>
          <p>Paste one OpenSSH public key after generating it with the selector above. Saving adds this device without removing keys already registered for your other devices.</p>
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
          <h3>Verify the server fingerprint</h3>
          <p>Before accepting the host key on the first connection, ask an administrator for the SFTP host-key fingerprint and compare it exactly with the prompt. Stop if a saved fingerprint changes unexpectedly.</p>
        </li>
        <li>
          <h3 class="os-panel windows">Mount from {sftpOsLabels.windows}</h3>
          <h3 class="os-panel macos">Mount from {sftpOsLabels.macos}</h3>
          <h3 class="os-panel linux">Mount from {sftpOsLabels.linux}</h3>
          <div class="os-panel windows">
            <SftpAccessDetails os="windows" username={username} serverHost={sftp.host} port={sftp.port} radioIdPrefix="sftp-setup" />
          </div>
          <div class="os-panel macos">
            <SftpAccessDetails os="macos" username={username} serverHost={sftp.host} port={sftp.port} radioIdPrefix="sftp-setup" />
          </div>
          <div class="os-panel linux">
            <SftpAccessDetails os="linux" username={username} serverHost={sftp.host} port={sftp.port} radioIdPrefix="sftp-setup" />
          </div>
          <p class="hint">Make the manual mount work first. Automatic mounts need a device key that can be unlocked without an interactive prompt, normally through the operating system's SSH agent or keychain; keep using the manual command if that is not configured.</p>
        </li>
      </ol>
      {filesWebAvailable ? (
        <p class="hint">Your account can also upload through https://files.{domain}; SSHFS is better for larger or repeated transfers.</p>
      ) : (
        <p class="hint">SFTP/SSHFS and browser Files access use separate permissions. Browser uploads are not currently available to your account.</p>
      )}
    </article>
  );
});
