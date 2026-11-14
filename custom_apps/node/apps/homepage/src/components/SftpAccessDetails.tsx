import { component$ } from '@builder.io/qwik';
import type { SftpOs } from '../shared/ui-types.js';
import { sshfsManualMountCommands, sshfsStartupMountCommands, sshfsUnmountCommands } from '../shared/ui-constants.js';
import { CommandSnippet } from './CommandSnippet.js';

const commandFor = (template: string, username: string, serverHost: string, port: number) =>
  template.split('{username}').join(username).split('{host}').join(serverHost).split('{port}').join(String(port));

const mountCommand = (os: SftpOs, username: string, serverHost: string, port: number) =>
  commandFor(sshfsManualMountCommands[os], username, serverHost, port);

const startupCommand = (os: SftpOs, username: string, serverHost: string, port: number) =>
  commandFor(sshfsStartupMountCommands[os], username, serverHost, port);

const runitStartupCommand = (username: string, serverHost: string, port: number) =>
  commandFor(sshfsStartupMountCommands.linuxRunit, username, serverHost, port);

export const SftpAccessDetails = component$(({
  os,
  username,
  serverHost,
  port,
  radioIdPrefix = 'sftp-access',
}: {
  os: SftpOs;
  username: string;
  serverHost: string;
  port: number;
  radioIdPrefix?: string;
}) => {
  const autoMountNote = (
    <p>Make the manual mount work first. Automatic mounts need a device key that can be unlocked without an interactive prompt, normally through the operating system's SSH agent or keychain; keep using the manual command if that is not configured.</p>
  );

  if (os === 'windows') {
    return (
      <div>
        <p>Install WinFsp and SSHFS-Win, then mount the server manually:</p>
        <CommandSnippet command={mountCommand(os, username, serverHost, port)} />
        <p>SSHFS-Win's key mode reads the private key at <code>$env:USERPROFILE\.ssh\id_rsa</code>. Protect that file like a password.</p>
        <p>Disconnect the drive with:</p>
        <CommandSnippet command={sshfsUnmountCommands[os]} />
        <details class="step-help auto-mount">
          <summary>Mount automatically at login</summary>
          {autoMountNote}
          <p>Mount the same drive automatically when Windows starts:</p>
          <CommandSnippet command={startupCommand(os, username, serverHost, port)} />
        </details>
      </div>
    );
  }

  if (os === 'macos') {
    return (
      <div>
        <p>Install macFUSE and sshfs, then mount the server manually:</p>
        <CommandSnippet command={mountCommand(os, username, serverHost, port)} />
        <p>Open ~/NixHomeServerFiles after the command completes. Unmount with:</p>
        <CommandSnippet command={sshfsUnmountCommands[os]} />
        <details class="step-help auto-mount">
          <summary>Mount automatically at login</summary>
          {autoMountNote}
          <p>Mount it automatically at login with a LaunchAgent:</p>
          <CommandSnippet command={startupCommand(os, username, serverHost, port)} />
        </details>
      </div>
    );
  }

  const systemdRadio = `${radioIdPrefix}-linux-systemd`;
  const runitRadio = `${radioIdPrefix}-linux-runit`;
  const initName = `${radioIdPrefix}-linux-init`;

  return (
    <div>
      <p>Install sshfs, then mount the server manually:</p>
      <CommandSnippet command={mountCommand(os, username, serverHost, port)} />
      <p>Open ~/NixHomeServerFiles after the command completes. Unmount with:</p>
      <CommandSnippet command={sshfsUnmountCommands[os]} />
      <details class="step-help auto-mount">
        <summary>Mount automatically at login</summary>
        {autoMountNote}
        <p>Choose the init system your Linux distribution uses:</p>
        <input class="os-radio" id={systemdRadio} name={initName} type="radio" checked />
        <input class="os-radio" id={runitRadio} name={initName} type="radio" />
        <div class="os-picker" role="tablist" aria-label="Linux init system">
          <label role="tab" for={systemdRadio}>systemd</label>
          <label role="tab" for={runitRadio}>runit</label>
        </div>
        <div class="linux-init-panel systemd">
          <p>For systemd-based distributions such as Ubuntu, Mint, and Debian, register a systemd user service:</p>
          <CommandSnippet command={startupCommand(os, username, serverHost, port)} />
        </div>
        <div class="linux-init-panel runit">
          <p>For runit-based distributions such as Void, enable Turnstile once, then register the mount as a per-user service (log out and back in if it does not start immediately):</p>
          <CommandSnippet command={runitStartupCommand(username, serverHost, port)} />
        </div>
      </details>
    </div>
  );
});
