import { component$ } from '@builder.io/qwik';

/**
 * Vaultwarden is the Passwords service used by this repository. Keep this guide
 * intentionally product-native: a separate KeePass database is not a backup of
 * a user's Vaultwarden vault.
 */
export const CredentialBackupGuide = component$(() => (
  <details class="credential-backup-guide">
    <summary>
      <span>
        <strong>Keep a recovery copy outside this server</strong>
        <small>Back up the passwords you actually store in Vaultwarden</small>
      </span>
    </summary>
    <div class="credential-backup-guide__content">
      <p>
        The Passwords app is this server&apos;s Vaultwarden service. Server backups help the administrator recover the
        service, but you should also keep a personal export that remains reachable if this server or its network is
        unavailable.
      </p>
      <aside class="guide-callout">
        A vault export contains highly sensitive data. Create it only on a trusted device, choose an encrypted export
        format when your client offers one, and never email it or place an unencrypted copy in cloud storage or Git.
      </aside>

      <h4>1. Confirm normal and offline access</h4>
      <ol class="steps">
        <li>Install an official Bitwarden client or browser extension on at least one trusted device and sign in to this server&apos;s Passwords URL.</li>
        <li>Sync the vault, then briefly disconnect the device from the network and confirm that you can still open an existing entry.</li>
        <li>Store the Vaultwarden master password and any two-step-login recovery details somewhere that does not depend only on this server.</li>
      </ol>

      <h4>2. Create a personal encrypted export</h4>
      <ol class="steps">
        <li>In the Passwords web vault or client, open <strong>Tools → Export vault</strong>.</li>
        <li>Prefer the password-protected encrypted JSON export when available. Record the export password separately from the export file. This portable encrypted JSON does <strong>not</strong> include file attachments.</li>
        <li>If attachments matter, make a separate <strong>.zip (with attachments)</strong> export. Treat that archive as plaintext vault data: move it immediately into an encrypted container or encrypted removable storage, then securely remove the browser download.</li>
        <li>Move the encrypted JSON to encrypted removable storage or another trusted off-server location, then remove temporary browser downloads and unencrypted copies.</li>
      </ol>
      <aside class="guide-callout neutral">
        Account-restricted encrypted exports may require the original account to import them. A password-protected
        encrypted export is usually more suitable for disaster recovery. Read the warning shown by your current client
        before choosing a format.
      </aside>

      <h4>3. Prove recovery works</h4>
      <ol class="steps">
        <li>Use a temporary test vault or another isolated trusted environment; do not overwrite your working vault.</li>
        <li>Unlock and import the encrypted JSON, then separately inspect the protected attachment archive if you created one. Confirm representative logins, secure notes, and attachments are recoverable.</li>
        <li>Delete the temporary restored data after the test. Repeat after major vault changes and at least every few months.</li>
      </ol>
      <p class="hint">The exact menu names and export formats depend on the Bitwarden client version. If an option is unclear, ask an administrator before creating a plaintext export.</p>
    </div>
  </details>
));
