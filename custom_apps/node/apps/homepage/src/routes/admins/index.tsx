import { $, Slot, component$, useContext, useSignal } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { AdminStep } from '../../shared/types.js';

type AdminCategoryId = 'daily' | 'deploys' | 'identity' | 'secrets';

type AdminStepMeta = {
  category: AdminCategoryId;
  badge: string;
};

const adminCategories: { id: AdminCategoryId; title: string; description: string }[] = [
  {
    id: 'daily',
    title: 'Daily Checks',
    description: 'Read-only checks for config state and service health.',
  },
  {
    id: 'deploys',
    title: 'Deploys',
    description: 'Validation, test builds, and the explicit system switch step.',
  },
  {
    id: 'identity',
    title: 'Access & Identity Maintenance',
    description: 'Lower-frequency identity cleanup and access lifecycle work.',
  },
  {
    id: 'secrets',
    title: 'Secrets',
    description: 'Sensitive credential generation and rotation tasks.',
  },
];

const adminStepMeta: Record<string, AdminStepMeta> = {
  'Review evaluated config': { category: 'daily', badge: 'Read-only' },
  'Check service health': { category: 'daily', badge: 'Read-only' },
  'Validate broad changes': { category: 'deploys', badge: 'Full gate' },
  'Run routine guarded deploy': { category: 'deploys', badge: 'Deploy test' },
  'Switch after a passing test': { category: 'deploys', badge: 'Switches system' },
  'Manage Kanidm entity removal explicitly': { category: 'identity', badge: 'Identity' },
  'Rotate or regenerate secrets': { category: 'secrets', badge: 'Sensitive' },
};

const fallbackStepMeta: AdminStepMeta = { category: 'daily', badge: 'Admin task' };

const metaForStep = (step: AdminStep): AdminStepMeta => adminStepMeta[step.title] ?? fallbackStepMeta;

const groupedAdminSteps = (steps: AdminStep[]) =>
  adminCategories
    .map((category) => ({
      ...category,
      steps: steps.filter((step) => metaForStep(step).category === category.id),
    }))
    .filter((category) => category.steps.length > 0);

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

const AdminTask = component$(
  ({ title, description, badges = [] }: { title: string; description: string; badges?: string[] }) => (
    <details class="admin-task">
      <summary class="admin-task__summary">
        <span class="admin-task__main">
          <span class="admin-task__title">{title}</span>
          <span class="admin-task__description">{description}</span>
        </span>
        {badges.length > 0 && (
          <span class="admin-task__badges">
            {badges.map((badge) => (
              <span class="admin-task__badge" key={badge}>
                {badge}
              </span>
            ))}
          </span>
        )}
      </summary>
      <div class="admin-task__content">
        <Slot />
      </div>
    </details>
  ),
);

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
  const adminSections = groupedAdminSteps(adminGuide);
  const typedUsername = username.value.trim();
  const typedUserGroups = currentUser && typedUsername === currentUser.username ? currentUser.groups : [];

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
        <div class="section-heading stacked">
          <div>
            <h2>Admin Command Center</h2>
            <p>Operator tasks grouped by intent. Expand only the task you need.</p>
          </div>
          <p class="admin-page-note">
            Initial disk provisioning, agenix key installation, and nixos-install happen from documentation/quickstart.md before this homepage exists.
          </p>
        </div>
        <div class="admin-command-layout">
          {adminSections.map((section) => (
            <section class="admin-command-section" key={section.id}>
              <div class="admin-command-section__heading">
                <h3>{section.title}</h3>
                <p>{section.description}</p>
              </div>
              <div class="admin-task-list">
                {section.steps.map((step) => (
                  <AdminTask title={step.title} description={step.detail} badges={[metaForStep(step).badge]} key={step.title}>
                    {step.command && <code>{step.command}</code>}
                  </AdminTask>
                ))}
              </div>
            </section>
          ))}
        </div>
      </section>
      <section class="section">
        <div class="section-heading stacked">
          <div>
            <h2>User Onboarding</h2>
            <p>Create identity first, grant only the access groups needed, then hand off first-sign-in and app setup.</p>
          </div>
        </div>
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
        <div class="admin-task-list">
          <AdminTask
            title="Check the user exists"
            description="Use this if re-running steps or after creation to confirm identity visibility."
            badges={['Identity']}
          >
            <code>{`kanidm person get ${userArg}`}</code>
          </AdminTask>
          <AdminTask
            title="Create the Kanidm account"
            description="Create the account record and set the primary email."
            badges={['Identity']}
          >
            <code>{`kanidm person create ${userArg} ${displayNameArg}`}</code>
            <code>{`kanidm person update ${userArg} --mail ${emailArg}`}</code>
          </AdminTask>
          <AdminTask
            title="Grant baseline access"
            description="Baseline identity membership enables Kanidm sign-in and normal user resolution."
            badges={['Required']}
          >
            <code>{`kanidm group add-members users ${userArg}`}</code>
          </AdminTask>
          <AdminTask
            title="Grant app/file/admin access"
            description="Pick one or more non-protected groups and run the generated command."
            badges={['Access groups']}
          >
            {accessGroups.length > 0 ? (
              <div class="group-picker">
                {accessGroups.map((group) => {
                  const isAlreadyMember = typedUserGroups.includes(group);
                  return (
                    <label key={group} class={`group-picker__option${isAlreadyMember ? ' is-member' : ''}`}>
                      <input
                        type="checkbox"
                        checked={selectedGroups.value.includes(group)}
                        onChange$={(event) => toggleGroup(group, event)}
                      />
                      <span class="group-name" title={groupDescriptions[group] ?? 'No description available'}>
                        {group}
                      </span>
                      {isAlreadyMember && <span class="group-status">Already assigned</span>}
                    </label>
                  );
                })}
              </div>
            ) : (
              <p>No non-protected groups are currently exposed from the configured Kanidm catalog.</p>
            )}
            <code>{membershipCommand}</code>
          </AdminTask>
          <AdminTask
            title="Signup for Vaultwarden"
            description="Users can register their own Vaultwarden account from the browser when trusted on LAN/NetBird."
            badges={['User action']}
          >
            <p>Have them open this URL and register with the same email used in Kanidm:</p>
            <code>{`https://passwords.${domain}/#/signup`}</code>
          </AdminTask>
          <AdminTask
            title="Create the first sign-in link"
            description="Generate a short-lived Kanidm reset link and share only through a secure channel."
            badges={['Sensitive']}
          >
            <code>{`kanidm person credential create-reset-token ${userArg} 3600`}</code>
          </AdminTask>
          <AdminTask
            title="Hand off first sign-in"
            description="Ask the person to complete Kanidm password and MFA setup, open each granted app once, and save recovery details securely."
            badges={['User action']}
          >
            <p>Confirm the user can sign in, open granted apps, and store recovery details somewhere durable.</p>
          </AdminTask>
        </div>
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
