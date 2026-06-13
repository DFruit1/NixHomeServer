import { component$ } from '@builder.io/qwik';
import type { SftpOs } from '../shared/ui-types.js';
import { SftpAccessDetails } from './SftpAccessDetails.js';

export const SftpAccessInstructions = component$(({ username, serverHost }: { username: string; serverHost: string }) => {
  const osRadio = {
    windows: 'sftp-access-windows',
    macos: 'sftp-access-macos',
    linux: 'sftp-access-linux',
  } as const;

  return (
    <div class="sftp-access-panel sftp-os-card sftp-access-card">
      <input class="os-radio" id={osRadio.windows} name="sftp-access-os" type="radio" defaultChecked />
      <input class="os-radio" id={osRadio.macos} name="sftp-access-os" type="radio" />
      <input class="os-radio" id={osRadio.linux} name="sftp-access-os" type="radio" />
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
      <div class="os-panel windows">
        <SftpAccessDetails os="windows" username={username} serverHost={serverHost} />
      </div>
      <div class="os-panel macos">
        <SftpAccessDetails os="macos" username={username} serverHost={serverHost} />
      </div>
      <div class="os-panel linux">
        <SftpAccessDetails os="linux" username={username} serverHost={serverHost} />
      </div>
    </div>
  );
});
