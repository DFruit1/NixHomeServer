import { component$ } from '@builder.io/qwik';
import { sftpKeygenCommands, sftpOsLabels } from '../shared/ui-constants.js';
import { SftpAccessDetails } from './SftpAccessDetails.js';

export const SftpSetup = component$(({ username, domain, serverHost }: { username: string; domain: string; serverHost: string }) => {
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
          <code class="os-panel windows">{sftpKeygenCommands.windows}</code>
          <code class="os-panel macos">{sftpKeygenCommands.macos}</code>
          <code class="os-panel linux">{sftpKeygenCommands.linux}</code>
        </li>
        <li>
          <h3>Upload the public key</h3>
          <p>Paste the public key output into <strong>Upload SSHFS Public Key</strong>, save it, then use the same OS selector to continue.</p>
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
