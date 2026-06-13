import { component$ } from '@builder.io/qwik';
import type { SftpOs } from '../shared/ui-types.js';
import { sshfsManualMountCommands, sshfsStartupMountCommands, sshfsUnmountCommands } from '../shared/ui-constants.js';
import { CommandSnippet } from './CommandSnippet.js';

const commandFor = (template: string, username: string, serverHost: string) =>
  template.split('{username}').join(username).split('{host}').join(serverHost);

const mountCommand = (os: SftpOs, username: string, serverHost: string) =>
  commandFor(sshfsManualMountCommands[os], username, serverHost);

const startupCommand = (os: SftpOs, username: string, serverHost: string) =>
  commandFor(sshfsStartupMountCommands[os], username, serverHost);

export const SftpAccessDetails = component$(({ os, username, serverHost }: { os: SftpOs; username: string; serverHost: string }) => {
  if (os === 'windows') {
    return (
      <div>
        <p>Install WinFsp and SSHFS-Win, then mount the server manually:</p>
        <CommandSnippet command={mountCommand(os, username, serverHost)} />
        <p>Mount the same drive automatically when Windows starts:</p>
        <CommandSnippet command={startupCommand(os, username, serverHost)} />
        <p>Use the private key at $env:USERPROFILE\\.ssh\\nixhomeserver-files when SSHFS-Win asks for authentication.</p>
        <p>Disconnect the drive with:</p>
        <CommandSnippet command={sshfsUnmountCommands[os]} />
      </div>
    );
  }

  if (os === 'macos') {
    return (
      <div>
        <p>Install macFUSE and sshfs, then mount the server manually:</p>
        <CommandSnippet command={mountCommand(os, username, serverHost)} />
        <p>Mount it automatically at login with a LaunchAgent:</p>
        <CommandSnippet command={startupCommand(os, username, serverHost)} />
        <p>Open ~/NixHomeServerFiles after the command completes. Unmount with:</p>
        <CommandSnippet command={sshfsUnmountCommands[os]} />
      </div>
    );
  }

  return (
    <div>
      <p>Install sshfs, then mount the server manually:</p>
      <CommandSnippet command={mountCommand(os, username, serverHost)} />
      <p>Mount it automatically at login with a systemd user service:</p>
      <CommandSnippet command={startupCommand(os, username, serverHost)} />
      <p>Open ~/NixHomeServerFiles after the command completes. Unmount with:</p>
      <CommandSnippet command={sshfsUnmountCommands[os]} />
    </div>
  );
});
