import { component$, useContext } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const adminGuide = homepage.data?.adminGuide ?? [];

  return (
    <>
      <section class="section">
        <div class="section-heading">
          <h2>Server Bootstrap</h2>
          <p>Operator checklist for a new host or a routine guarded deploy.</p>
        </div>
        <ol class="admin-steps">
          {adminGuide.map((step) => (
            <li key={step.title}>
              <h3>{step.title}</h3>
              <p>{step.detail}</p>
              {step.command && <code>{step.command}</code>}
            </li>
          ))}
        </ol>
      </section>
      <section class="section">
        <div class="section-heading stacked">
          <h2>New User Onboarding</h2>
          <p>Create identity first, grant only the access groups needed, then hand off first-sign-in and app setup.</p>
        </div>
        <ol class="admin-steps">
          <li>
            <h3>Create the Kanidm account</h3>
            <p>Use the guided admin tool or create the account directly with a username, display name, and primary email.</p>
            <code>kanidm-admin user create "$NEW_USER" --display-name "$DISPLAY_NAME" --email "$EMAIL"</code>
          </li>
          <li>
            <h3>Grant baseline access</h3>
            <p>Add the account to the baseline users group, then add only the app, file, or admin groups the person should have.</p>
            <code>kanidm-admin membership add "$NEW_USER" users</code>
          </li>
          <li>
            <h3>Add file access when needed</h3>
            <p>Use user-files for browser Files access, files-sftp-users for direct SFTP, and files-shared-users for the shared folder view.</p>
            <code>kanidm-admin membership add "$NEW_USER" user-files files-sftp-users files-shared-users</code>
          </li>
          <li>
            <h3>Invite password-manager users</h3>
            <p>Vaultwarden is local-auth only, so invite the Kanidm primary email when the person should use Passwords.</p>
            <code>kanidm-admin local vaultwarden invite "$NEW_USER"</code>
          </li>
          <li>
            <h3>Create the first sign-in link</h3>
            <p>Generate a short-lived reset link and share it only through a secure channel so the person can set credentials and MFA.</p>
            <code>kanidm-admin user reset-token "$NEW_USER" --ttl 3600</code>
          </li>
          <li>
            <h3>Hand off first sign-in</h3>
            <p>Ask the person to complete Kanidm password and MFA setup, open each granted app once, and save recovery details securely.</p>
          </li>
        </ol>
      </section>
      <section class="section two-column">
        <div>
          <h2>Daily Operations</h2>
          <ol class="steps">
            <li>Use the guarded deploy helper for rebuild tests and switches.</li>
            <li>Check failed systemd units before switching after a test deploy.</li>
            <li>Keep generated secrets encrypted in agenix and do not commit plaintext secret material.</li>
          </ol>
        </div>
        <div>
          <h2>User Support</h2>
          <ol class="steps">
            <li>Grant users the right Kanidm groups before asking them to open apps.</li>
            <li>For phone backup, configure the phone Syncthing device ID before enabling the phone-backup module.</li>
            <li>Use the Backups service page to help users scan the server Syncthing details.</li>
          </ol>
        </div>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'For Admins | Sydney Basin Services',
};
