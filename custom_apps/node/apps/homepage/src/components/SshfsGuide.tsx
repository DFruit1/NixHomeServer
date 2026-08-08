import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import type { SftpAccess } from '../shared/types.js';

export const SshfsGuide = component$(({
  sftp,
  filesWebAvailable,
}: {
  sftp: SftpAccess;
  filesWebAvailable: boolean;
}) => (
  <article id="guide-detail" class="guide-panel detailed-service-guide">
    <span class="eyebrow">File access guide</span>
    <h2>SSHFS Mount</h2>
    {!sftp.allowed && (
      <aside class="guide-callout neutral">
        Your account does not currently have SSHFS access. This topic is shown because “Show unused apps in Detailed Guide” is on.
      </aside>
    )}
    <p>SSHFS mounts your restricted server file view as a folder or drive on a computer. It is best for large transfers, repeated library maintenance, and tools that expect a normal filesystem.</p>

    <section>
      <h3>When to use SSHFS</h3>
      <ul class="guide-checklist">
        <li>Use Files in the browser for a handful of uploads or quick organisation.</li>
        <li>Use SSHFS when you regularly copy many files, need resumable operating-system tools, or want the server available beside local folders.</li>
        <li>Use an app’s own uploader instead when the app needs to process metadata during upload, especially Photos and Documents.</li>
      </ul>
      <aside class="guide-callout neutral">SFTP/SSHFS and browser Files access use separate permissions. {filesWebAvailable ? 'Your account currently has both.' : 'Browser Files is not currently available to your account.'}</aside>
    </section>

    <section>
      <h3>Connection and security</h3>
      {sftp.allowed ? (
        <dl class="info-list">
          <div>
            <dt>Server</dt>
            <dd>{sftp.host}:{sftp.port}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{sftp.networkNote}</dd>
          </div>
        </dl>
      ) : (
        <p>Ask an administrator to grant SSHFS access before requesting the connection address or registering a device key.</p>
      )}
      <ul class="guide-checklist">
        <li>The setup creates a key pair on your device. Upload only the public key; the private key must never leave that device.</li>
        <li>Before accepting the first connection, compare the server fingerprint with one provided by an administrator through a trusted channel.</li>
        <li>Make a manual mount work before configuring automatic mounting. Automatic mounts also need the device to unlock its key without an interactive prompt, so it is recommended to leave the key passphrase empty for simplicity. If you want to prevent the key being used without your permission, store it in an SSH keyring such as KeePassXC's SSH Agent or an alternative keyring rather than as a plain file on disk.</li>
      </ul>
    </section>

    {sftp.accessNotes.length > 0 && (
      <section>
        <h3>Folders visible to your account</h3>
        {sftp.accessNotes.map((note) => <aside class="guide-callout neutral" key={note}>{note}</aside>)}
      </section>
    )}

    <section>
      <h3>If the mount fails</h3>
      <ul class="guide-checklist">
        <li>Confirm the computer is on the home network. The SSHFS port is not exposed through the public web tunnel or ordinary NetBird web access.</li>
        <li>Check the configured host and port, then verify that the saved host fingerprint has not changed unexpectedly.</li>
        <li>If authentication fails, confirm the device’s public key was saved and that its matching private key is selected.</li>
        <li>If a folder is missing or read-only, check the role-specific notes above; browser, personal, shared, USB, and backup views are separately authorised.</li>
      </ul>
    </section>

    {sftp.allowed && (
      <div class="detail-actions">
        <Link class="primary-link" href="/getting-started?step=uploads#sshfs-setup">Set up SSHFS in Getting Started</Link>
      </div>
    )}
  </article>
));
