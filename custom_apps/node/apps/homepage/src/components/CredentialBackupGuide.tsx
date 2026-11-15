import { component$ } from '@builder.io/qwik';

/**
 * Vaultwarden is the Passwords service used by this repository. Keep this guide
 * product-native: a separate KeePass database is not a backup of a user's
 * Vaultwarden vault.
 */
export const CredentialBackupGuide = component$(({ passwordsUrl, enabled }: { passwordsUrl?: string; enabled: boolean }) => (
  <article id="guide-detail" class="guide-topic doc-prose">
    <header class="guide-topic__head">
      <div class="guide-topic__title">
        <h1>Back up your password vault</h1>
      </div>
      {enabled && passwordsUrl && (
        <p class="doc-actions">
          <a class="doc-btn doc-btn--primary" href={passwordsUrl} target="_blank" rel="noreferrer">Open Passwords</a>
        </p>
      )}
    </header>
    {!enabled && <p class="doc-note">Passwords is not enabled for your account. This topic is listed because “Include apps that are not enabled” is on.</p>}
    <p class="doc-lead">
      Server backups let an admin restore the Passwords service. They do not help you if this server or its network is unavailable, so keep a copy of your own.
    </p>
    <p class="doc-warn">
      <strong>An export contains every password you have.</strong> Create it only on a device you trust, choose an encrypted format, and never email it or leave an unencrypted copy in cloud storage.
    </p>

    <h2>1. Check you can read your vault offline</h2>
    <ol class="doc-steps">
      <li>Install an official Bitwarden app or browser extension on a trusted device and sign in to this server’s Passwords address.</li>
      <li>Let it sync, disconnect the device from the network for a moment, and check that you can still open an entry.</li>
      <li>Keep your master password and any two-step-login recovery details somewhere that does not depend on this server.</li>
    </ol>

    <h2>2. Make an encrypted export</h2>
    <ol class="doc-steps">
      <li>In Passwords, open <strong>Tools → Export vault</strong>.</li>
      <li>Choose the password-protected encrypted JSON export. Keep the export password apart from the file. This format does <strong>not</strong> include file attachments.</li>
      <li>If attachments matter, make a separate <strong>.zip (with attachments)</strong> export. Treat that archive as plaintext vault data: move it straight into encrypted storage, then delete the browser download.</li>
      <li>Move the encrypted JSON to encrypted removable storage or another trusted place off this server, then delete temporary downloads.</li>
    </ol>
    <p class="doc-note">
      An account-restricted export can only be imported by the account that made it. A password-protected export is usually the better choice for disaster recovery.
    </p>

    <h2>3. Prove the backup works</h2>
    <ol class="doc-steps">
      <li>Use a temporary test vault, not your working one.</li>
      <li>Import the encrypted JSON and check that a few logins, notes and attachments are there.</li>
      <li>Delete the test data. Repeat after big changes and at least every few months.</li>
    </ol>
    <p class="doc-note">Menu names and export formats vary between Bitwarden versions. If an option is unclear, ask an admin before making a plaintext export.</p>
  </article>
));
