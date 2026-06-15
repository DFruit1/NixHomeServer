import { $, component$, useContext, useSignal } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';

const isProtectedGroup = (group: string): boolean =>
  group === 'users' || group === 'system_admins' || group === 'domain_admins' || group.startsWith('idm_');

const shellSingleQuote = (value: string): string => {
  const escaped = value.replace(/'/g, `'\\''`);
  return `'${escaped}'`;
};

const buildUserArg = (username: string): string =>
  username.trim() ? shellSingleQuote(username.trim()) : '"$NEW_USER"';

const buildEmailArg = (email: string): string =>
  email.trim() ? shellSingleQuote(email.trim()) : '"$EMAIL"';

const buildDisplayNameArg = (username: string): string => {
  const trimmed = username.trim();
  return trimmed ? shellSingleQuote(trimmed) : '"$DISPLAY_NAME"';
};

const buildMembershipCommands = (groups: string[], userArg: string): string[] => {
  if (groups.length === 0) {
    return [];
  }
  const quotedGroups = groups
    .map((group) => group.trim())
    .filter((group) => group.length > 0)
    .sort()
    .map((group) => shellSingleQuote(group))
    .join(' ');
  return [`for group in ${quotedGroups}; do`, `  kanidm group add-members "$group" ${userArg}`, 'done'];
};

const formatCommandBlock = (commands: string[]): string =>
  commands.length ? commands.join('\n') : '# Select one or more access groups above, then copy generated commands.';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const adminGuide = homepage.data?.adminGuide ?? [];
  const domain = homepage.data?.domain ?? 'example.test';
  const currentUser = homepage.data?.user;
  const username = useSignal('');
  const email = useSignal('');
  const groupDescriptions = homepage.data?.kanidmGroupDescriptions ?? {};
  const accessGroups = (homepage.data?.kanidmGroups ?? [])
    .filter((group) => !isProtectedGroup(group))
    .sort((a, b) => a.localeCompare(b));
  const selectedGroups = useSignal<string[]>([]);

  const userArg = buildUserArg(username.value);
  const emailArg = buildEmailArg(email.value);
  const displayNameArg = buildDisplayNameArg(username.value);

  const membershipCommand = formatCommandBlock(buildMembershipCommands(selectedGroups.value, userArg));

  const setUsername = $((event: Event) => {
    const input = event.target as HTMLInputElement;
    username.value = input.value;
  });

  const setEmail = $((event: Event) => {
    const input = event.target as HTMLInputElement;
    email.value = input.value;
  });

  const fillMe = $(() => {
    username.value = currentUser?.username ?? '';
    email.value = currentUser?.email ?? '';
  });

  const toggleGroup = $((group: string, event: Event) => {
    const input = event.target as HTMLInputElement;
    selectedGroups.value = input.checked
      ? [...new Set([...selectedGroups.value, group])].sort()
      : selectedGroups.value.filter((current) => current !== group);
  });

  return (
    <>
      <section class="section">
        <details class="admin-accordion" open>
          <summary class="admin-accordion__summary">
            <h2>Server Management</h2>
            <p>Operator checklist for an already-installed host.</p>
          </summary>
          <div class="admin-accordion__content">
            <p>
              Initial disk provisioning, agenix key installation, and nixos-install happen from documentation/quickstart.md before this homepage exists.
            </p>
            <ol class="admin-steps">
              {adminGuide.map((step) => (
                <li key={step.title}>
                  <h3>{step.title}</h3>
                  <p>{step.detail}</p>
                  {step.command && <code>{step.command}</code>}
                </li>
              ))}
            </ol>
          </div>
        </details>
      </section>
      <section class="section">
        <details class="admin-accordion" open>
          <summary class="admin-accordion__summary">
            <h2>New User Onboarding</h2>
            <p>Create identity first, grant only the access groups needed, then hand off first-sign-in and app setup.</p>
          </summary>
          <div class="admin-accordion__content">
            <div class="admin-input-grid">
              <label>
                Username
                <input type="text" value={username.value} onInput$={setUsername} placeholder="alice" />
              </label>
              <label>
                Email
                <input type="email" value={email.value} onInput$={setEmail} placeholder="alice@example.com" />
              </label>
            </div>
            <div class="admin-fill-row">
              <button type="button" class="admin-fill-btn" onClick$={fillMe}>
                It's for me
              </button>
            </div>
            <ol class="admin-steps">
              <li>
                <h3>Check the user exists</h3>
                <p>Use this if re-running steps or after creation to confirm identity visibility.</p>
                <code>{`kanidm person get ${userArg}`}</code>
              </li>
              <li>
                <h3>Create the Kanidm account</h3>
                <p>Create the account record and set the primary email.</p>
                <code>{`kanidm person create ${userArg} ${displayNameArg}`}</code>
                <code>{`kanidm person update ${userArg} --mail ${emailArg}`}</code>
              </li>
              <li>
                <h3>Grant baseline access</h3>
                <p>Baseline identity membership enables Kanidm sign-in and normal user resolution.</p>
                <code>{`kanidm group add-members users ${userArg}`}</code>
              </li>
              <li>
                <h3>Grant app/file/admin access</h3>
                <p>Pick one or more non-protected groups and run the generated command.</p>
                {accessGroups.length > 0 ? (
                  <div class="group-picker">
                    {accessGroups.map((group) => (
                      <label key={group} class="group-picker__option">
                        <input
                          type="checkbox"
                          checked={selectedGroups.value.includes(group)}
                          onChange$={(event) => toggleGroup(group, event)}
                        />
                        <span class="group-name" title={groupDescriptions[group] ?? 'No description available'}>
                          {group}
                        </span>
                      </label>
                    ))}
                  </div>
                ) : (
                  <p>No non-protected groups are currently exposed from the configured Kanidm catalog.</p>
                )}
                <code>{membershipCommand}</code>
              </li>
              <li>
                <h3>Signup for Vaultwarden</h3>
                <p>Users can register their own Vaultwarden account from the browser when trusted on LAN/NetBird.</p>
                <p>Have them open this URL and register with the same email used in Kanidm:</p>
                <code>{`https://passwords.${domain}/#/signup`}</code>
              </li>
              <li>
                <h3>Create the first sign-in link</h3>
                <p>Generate a short-lived Kanidm reset link and share only through a secure channel.</p>
                <code>{`kanidm person credential create-reset-token ${userArg} 3600`}</code>
              </li>
              <li>
                <h3>Hand off first sign-in</h3>
                <p>Ask the person to complete Kanidm password and MFA setup, open each granted app once, and save recovery details securely.</p>
              </li>
            </ol>
          </div>
        </details>
      </section>
      <section class="section two-column">
        <div>
          <h2>Config And Deploys</h2>
          <ol class="steps">
            <li>Use vars.nix for operator-facing host, network, storage, domain, and access settings.</li>
            <li>Use configuration.nix imports to enable or remove optional app modules.</li>
            <li>Run the guarded deploy test before switching the active system.</li>
            <li>Keep generated secrets encrypted in agenix and do not commit plaintext secret material.</li>
          </ol>
        </div>
        <div>
          <h2>User Support</h2>
          <ol class="steps">
            <li>Grant users the right Kanidm groups before asking them to open apps.</li>
            <li>Use the generated onboarding commands above for account creation and group membership.</li>
            <li>For phone backup, configure the phone Syncthing device ID before enabling the phone-backup module.</li>
            <li>Use the Local Backups and Offline Media service pages after each relevant device ID is known.</li>
          </ol>
        </div>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'For Admins | Sydney Basin Services',
};
