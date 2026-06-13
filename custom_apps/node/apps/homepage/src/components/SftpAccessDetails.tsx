import { component$ } from '@builder.io/qwik';
import type { SftpOs } from '../shared/ui-types.js';
import { sshfsMountCommands } from '../shared/ui-constants.js';

const mountCommand = (os: SftpOs, username: string, serverHost: string) =>
  sshfsMountCommands[os].replace('{username}', username).replace('{host}', serverHost);

export const SftpAccessDetails = component$(({ os, username, serverHost }: { os: SftpOs; username: string; serverHost: string }) => {
  if (os === 'windows') {
    return (
      <div>
        <p>Install WinFsp and SSHFS-Win, then mount the server as a drive:</p>
        <code>{mountCommand(os, username, serverHost)}</code>
        <p>Use the private key at $env:USERPROFILE\\.ssh\\nixhomeserver-files when SSHFS-Win asks for authentication.</p>
      </div>
    );
  }

  if (os === 'macos') {
    return (
      <div>
        <p>Install macFUSE and sshfs, then mount the server into your home folder:</p>
        <code>{mountCommand(os, username, serverHost)}</code>
        <p>Open ~/NixHomeServerFiles after the command completes.</p>
      </div>
    );
  }

  return (
    <div>
      <p>Install sshfs, then mount the server into your home folder:</p>
      <code>{mountCommand(os, username, serverHost)}</code>
      <p>Open ~/NixHomeServerFiles after the command completes. Unmount with fusermount -u ~/NixHomeServerFiles.</p>
    </div>
  );
});
