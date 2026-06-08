import { component$ } from '@builder.io/qwik';
import { sftpKeygenCommands, sftpOsLabels } from '../shared/ui-constants.js';
import { SftpAccessDetails } from './SftpAccessDetails.js';

export const SftpSetup = component$(({ username, domain }: { username: string; domain: string }) => {
  return (
    <article class="sftp-os-card sftp-setup-card">
      <h2>Direct SFTP Setup</h2>
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
          <h3>Generate an SFTP key pair</h3>
          <p>Run this on your device. If you want password-protected key access, set a passphrase when ssh-keygen asks for one.</p>
          <code class="os-panel windows">{sftpKeygenCommands.windows}</code>
          <code class="os-panel macos">{sftpKeygenCommands.macos}</code>
          <code class="os-panel linux">{sftpKeygenCommands.linux}</code>
        </li>
        <li>
          <h3>Upload the public key</h3>
          <p>Paste the public key output into Upload SFTP Public Key, then save it before connecting.</p>
        </li>
        <li>
          <h3 class="os-panel windows">Connect from {sftpOsLabels.windows}</h3>
          <h3 class="os-panel macos">Connect from {sftpOsLabels.macos}</h3>
          <h3 class="os-panel linux">Connect from {sftpOsLabels.linux}</h3>
          <div class="os-panel windows">
            <SftpAccessDetails os="windows" username={username} />
          </div>
          <div class="os-panel macos">
            <SftpAccessDetails os="macos" username={username} />
          </div>
          <div class="os-panel linux">
            <SftpAccessDetails os="linux" username={username} />
          </div>
        </li>
      </ol>
      <p class="hint">Browser uploads still work at https://files.{domain}; SFTP is for larger or repeated transfers.</p>
    </article>
  );
});
