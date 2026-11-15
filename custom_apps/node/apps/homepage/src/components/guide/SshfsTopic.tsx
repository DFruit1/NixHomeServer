import { component$ } from '@builder.io/qwik';
import type { SftpAccess } from '../../shared/types.js';
import { SftpSetup } from '../SftpSetup.js';

/** What SSHFS is for, what this account will see, the setup itself, and what to check when it fails. */
export const SshfsTopic = component$(({
  sftp,
  username,
  filesUrl,
}: {
  sftp: SftpAccess;
  username: string;
  /** Set when the account can also upload through the browser Files app. */
  filesUrl?: string;
}) => (
  <article id="guide-detail" class="guide-topic doc-prose">
    <header class="guide-topic__head">
      <div class="guide-topic__title">
        <h1>Mount your files as a drive</h1>
        <p>SSHFS</p>
      </div>
    </header>
    <p class="doc-lead">SSHFS makes your server files appear as an ordinary folder or drive on a computer. Use it for large transfers, regular library upkeep, and tools that expect a normal folder.</p>

    {!sftp.allowed ? (
      <p class="doc-note">
        Your account does not currently have SSHFS access. Ask an administrator to grant it before requesting the connection address or registering a device key.
      </p>
    ) : (
      <>
        <dl class="doc-facts">
          <div>
            <dt>Server</dt>
            <dd><code>{sftp.host}:{sftp.port}</code></dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{sftp.networkNote}</dd>
          </div>
          <div>
            <dt>Browser uploads</dt>
            <dd>
              SFTP/SSHFS and browser Files access use separate permissions.{' '}
              {filesUrl
                ? <>Your account can also upload through <a href={filesUrl} target="_blank" rel="noreferrer">{filesUrl}</a>, which is quicker for a few files.</>
                : 'Browser Files is not currently available to your account.'}
            </dd>
          </div>
        </dl>

        {sftp.accessNotes.length > 0 && (
          <>
            <h2>What you will see</h2>
            <ul class="sshfs-access-notes">
              {sftp.accessNotes.map((note) => <li key={note}>{note}</li>)}
            </ul>
          </>
        )}

        <h2>Set it up</h2>
        <p>Do this once on each computer. The key pair is created on your device: only the public half is uploaded, and the private half must never leave it.</p>
        <SftpSetup username={username} sftp={sftp} />

        <h2>If the mount fails</h2>
        <ul>
          <li>Check the computer is on the home network. This port is not reachable through the public web address or ordinary NetBird web access.</li>
          <li>Check the host and port above, and that the saved host fingerprint has not changed unexpectedly.</li>
          <li>If sign-in is refused, check that this device’s public key was saved and that the matching private key is the one being used.</li>
          <li>If a folder is missing or read-only, check the list of what you will see. Personal, shared, USB and backup views are each granted separately.</li>
        </ul>
      </>
    )}
  </article>
));
