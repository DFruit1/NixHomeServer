import { component$ } from '@builder.io/qwik';
import type { SftpOs } from '../shared/ui-types.js';

export const SftpAccessDetails = component$(({ os, username }: { os: SftpOs; username: string }) => {
  if (os === 'windows') {
    return (
      <div>
        <p>Use WinSCP with these settings:</p>
        <dl class="info-list compact">
          <div>
            <dt>Protocol</dt>
            <dd>SFTP</dd>
          </div>
          <div>
            <dt>Host</dt>
            <dd>server.home.arpa</dd>
          </div>
          <div>
            <dt>Port</dt>
            <dd>2222</dd>
          </div>
          <div>
            <dt>Username</dt>
            <dd>{username}</dd>
          </div>
          <div>
            <dt>Private key</dt>
            <dd>$env:USERPROFILE\\.ssh\\nixhomeserver-files</dd>
          </div>
        </dl>
      </div>
    );
  }

  if (os === 'macos') {
    return (
      <div>
        <p>In Finder, choose Go &gt; Connect to Server, then enter:</p>
        <code>sftp://{username}@server.home.arpa:2222/</code>
        <p>When prompted, select the private key that matches the public key you uploaded.</p>
      </div>
    );
  }

  return (
    <div>
      <p>In Nemo, choose File &gt; Connect to Server, then use:</p>
      <code>sftp://{username}@server.home.arpa:2222/</code>
      <p>When prompted, select the private key that matches the public key you uploaded.</p>
    </div>
  );
});
