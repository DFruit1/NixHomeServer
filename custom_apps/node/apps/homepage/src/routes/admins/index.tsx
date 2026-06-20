import { $, Slot, component$, useContext, useSignal } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { AdminStep } from '../../shared/types.js';

type AdminCategoryId = 'daily' | 'deploys' | 'apps' | 'identity' | 'storage' | 'backups' | 'network' | 'secrets';
type AdminIntentId = 'add-user' | 'manage-user' | 'manage-secrets';

type AdminStepMeta = {
  category: AdminCategoryId;
  intents?: AdminIntentId[];
};

const adminCategories: { id: AdminCategoryId; title: string; description: string }[] = [
  {
    id: 'daily',
    title: 'Daily Checks',
    description: 'Read-only config and health checks.',
  },
  {
    id: 'deploys',
    title: 'Deploys',
    description: 'Validation, test builds, switch step.',
  },
  {
    id: 'apps',
    title: 'Apps & Services',
    description: 'Service status, logs, and app reconciliation.',
  },
  {
    id: 'identity',
    title: 'Access & Identity Maintenance',
    description: 'Identity cleanup and access lifecycle.',
  },
  {
    id: 'storage',
    title: 'Storage',
    description: 'Disk, filesystem, pool, and SMART checks.',
  },
  {
    id: 'backups',
    title: 'Backups',
    description: 'Snapshot, repository, and offsite sync operations.',
  },
  {
    id: 'network',
    title: 'Network & Edge',
    description: 'Caddy, DNS, Cloudflare tunnel, and NetBird checks.',
  },
  {
    id: 'secrets',
    title: 'Secrets',
    description: 'Credential generation and rotation.',
  },
];

const adminStepMeta: Record<string, AdminStepMeta> = {
  'Review evaluated config': { category: 'daily' },
  'Validate config readiness': { category: 'daily' },
  'Export operations inventory': { category: 'daily' },
  'Check git worktree': { category: 'daily' },
  'Check service health': { category: 'daily' },
  'List scheduled timers': { category: 'daily' },
  'Review current boot warnings': { category: 'daily' },
  'Show resource snapshot': { category: 'daily' },
  'Validate broad changes': { category: 'deploys' },
  'Run lean repo validation': { category: 'deploys' },
  'Run full repo validation': { category: 'deploys' },
  'Evaluate flake without building': { category: 'deploys' },
  'Dry-run deploy target resolution': { category: 'deploys' },
  'Run routine guarded deploy': { category: 'deploys' },
  'Run guarded deploy with local build': { category: 'deploys' },
  'Switch after a passing test': { category: 'deploys' },
  'Show generations for rollback': { category: 'deploys' },
  'Rollback current generation': { category: 'deploys' },
  'Check app service status': { category: 'apps' },
  'Follow app logs': { category: 'apps' },
  'Restart a single app service': { category: 'apps' },
  'Restart homepage': { category: 'apps' },
  'Check OAuth proxy logs': { category: 'apps' },
  'Re-run storage layout services': { category: 'apps' },
  'Re-run Immich OIDC reconcile': { category: 'apps' },
  'Re-run Paperless OIDC reconcile': { category: 'apps' },
  'Re-run Jellyfin library sync': { category: 'apps' },
  'Re-run Kiwix library sync': { category: 'apps' },
  'Check Kanidm health': { category: 'identity' },
  'List Kanidm people': { category: 'identity', intents: ['manage-user'] },
  'List Kanidm groups': { category: 'identity' },
  'Inspect Kanidm group': { category: 'identity', intents: ['manage-user'] },
  'Remove user from access group': { category: 'identity', intents: ['manage-user'] },
  'Restart identity reconciliation': { category: 'identity' },
  'Manage Kanidm entity removal explicitly': { category: 'identity', intents: ['manage-user'] },
  'Show mounted filesystems': { category: 'storage' },
  'Show disk layout': { category: 'storage' },
  'Discover monitored storage devices': { category: 'storage' },
  'Check ZFS pool status': { category: 'storage' },
  'Start ZFS scrub': { category: 'storage' },
  'Show Btrfs filesystem usage': { category: 'storage' },
  'Check Btrfs scrub status': { category: 'storage' },
  'Run SMART short sweep': { category: 'storage' },
  'Inspect a disk with SMART': { category: 'storage' },
  'Check storage monitor logs': { category: 'storage' },
  'Check backup timers': { category: 'backups' },
  'Check Kopia services': { category: 'backups' },
  'Run persist snapshot now': { category: 'backups' },
  'Inspect persist snapshot logs': { category: 'backups' },
  'Run phone backup snapshot now': { category: 'backups' },
  'Run offsite Kopia sync now': { category: 'backups' },
  'Inspect offsite sync logs': { category: 'backups' },
  'Check backup repository size': { category: 'backups' },
  'Check Caddy status': { category: 'network' },
  'Validate Caddy config': { category: 'network' },
  'Reload Caddy': { category: 'network' },
  'Inspect Caddy logs': { category: 'network' },
  'Check Unbound status': { category: 'network' },
  'Query private DNS': { category: 'network' },
  'Check Cloudflare tunnel status': { category: 'network' },
  'Inspect Cloudflare tunnel logs': { category: 'network' },
  'Check NetBird status': { category: 'network' },
  'Inspect firewall rules': { category: 'network' },
  'Rotate or regenerate secrets': { category: 'secrets', intents: ['manage-secrets'] },
  'List encrypted secrets': { category: 'secrets', intents: ['manage-secrets'] },
  'List expected external secrets': { category: 'secrets', intents: ['manage-secrets'] },
  'Edit staged external secret': { category: 'secrets', intents: ['manage-secrets'] },
  'Encrypt staged external secrets': { category: 'secrets', intents: ['manage-secrets'] },
};

const fallbackStepMeta: AdminStepMeta = { category: 'daily' };

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

const adminIntents: { id: AdminIntentId; label: string }[] = [
  { id: 'add-user', label: 'Add New User' },
  { id: 'manage-user', label: 'Manage Existing User' },
  { id: 'manage-secrets', label: 'Manage Secrets / Passwords' },
];

const isIntentOpen = (activeIntent: AdminIntentId | '', intents: AdminIntentId[] = []): boolean =>
  activeIntent !== '' && intents.includes(activeIntent);

const shouldShowForIntent = (activeIntent: AdminIntentId | '', intents: AdminIntentId[] = []): boolean =>
  activeIntent === '' || intents.includes(activeIntent);

const AdminCommand = component$(({ command }: { command: string }) => {
  const copied = useSignal(false);

  const copyCommand = $(async () => {
    if (!navigator.clipboard?.writeText) {
      return;
    }
    await navigator.clipboard.writeText(command);
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, 1600);
  });

  return (
    <div class="admin-code-card">
      <code>{command}</code>
      <button type="button" class="admin-code-card__copy" aria-label={copied.value ? 'Copied command' : 'Copy command'} onClick$={copyCommand}>
        {copied.value ? (
          <svg aria-hidden="true" viewBox="0 0 24 24">
            <path d="M20 6 9 17l-5-5" />
          </svg>
        ) : (
          <svg aria-hidden="true" viewBox="0 0 24 24">
            <rect x="9" y="9" width="10" height="10" rx="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        )}
      </button>
    </div>
  );
});

const AdminTask = component$(
  ({
    title,
    description,
    activeIntent,
    intents = [],
  }: {
    title: string;
    description: string;
    activeIntent: AdminIntentId | '';
    intents?: AdminIntentId[];
  }) => (
    <details class="admin-task" open={isIntentOpen(activeIntent, intents)}>
      <summary class="admin-task__summary">
        <span class="admin-task__main">
          <span class="admin-task__title">{title}</span>
        </span>
      </summary>
      <div class="admin-task__content">
        <p>{description}</p>
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
  const selectedIntent = useSignal<AdminIntentId | ''>('');
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
  const visibleAdminSections = adminSections
    .map((section) => ({
      ...section,
      steps: selectedIntent.value
        ? section.steps.filter((step) => shouldShowForIntent(selectedIntent.value, metaForStep(step).intents))
        : section.steps,
    }))
    .filter((section) => section.steps.length > 0);
  const typedUsername = username.value.trim();
  const typedUserGroups = currentUser && typedUsername === currentUser.username ? currentUser.groups : [];
  const unassignedAccessGroups = accessGroups.filter((group) => !typedUserGroups.includes(group));
  const assignedAccessGroups = accessGroups.filter((group) => typedUserGroups.includes(group));
  const showUserManagement = selectedIntent.value === '' || ['add-user', 'manage-user', 'manage-secrets'].includes(selectedIntent.value);

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

  const selectIntent = $((intent: AdminIntentId) => {
    selectedIntent.value = selectedIntent.value === intent ? '' : intent;
  });

  const renderGroupOption = (group: string) => (
    <label key={group} class="group-picker__option">
      <input type="checkbox" checked={selectedGroups.value.includes(group)} onChange$={(event) => toggleGroup(group, event)} />
      <span class="group-name" title={groupDescriptions[group] ?? 'No description available'}>
        {group}
      </span>
    </label>
  );

  return (
    <>
      <section class="section">
        <div class={{ 'admin-intent-hero': true, 'is-compact': selectedIntent.value !== '' }}>
          <h2 aria-hidden={selectedIntent.value !== ''}>What do you need to do?</h2>
          <div class="admin-intent-actions" role="group" aria-label="Common admin tasks">
            {adminIntents.map((intent) => (
              <button
                type="button"
                class={{ selected: selectedIntent.value === intent.id }}
                aria-pressed={selectedIntent.value === intent.id}
                onClick$={() => selectIntent(intent.id)}
                key={intent.id}
              >
                {intent.label}
              </button>
            ))}
          </div>
          <p class="admin-page-note" aria-hidden={selectedIntent.value !== ''}>
            Quickstart covers disk setup, agenix keys, and nixos-install before homepage exists.
          </p>
        </div>
        {visibleAdminSections.length > 0 && (
          <div class="admin-command-layout">
            {visibleAdminSections.map((section) => (
              <details class="admin-command-category" open={selectedIntent.value !== ''} key={section.id}>
                <summary class="admin-command-category__summary">
                  <span class="admin-command-category__heading">
                    <h3>{section.title}</h3>
                    <p>{section.description}</p>
                  </span>
                </summary>
                <div class="admin-task-list">
                  {section.steps.map((step) => (
                    <AdminTask
                      title={step.title}
                      description={step.detail}
                      activeIntent={selectedIntent.value}
                      intents={metaForStep(step).intents}
                      key={step.title}
                    >
                      {step.command && <AdminCommand command={step.command} />}
                    </AdminTask>
                  ))}
                </div>
              </details>
            ))}
          </div>
        )}
      </section>
      {showUserManagement && (
        <section class="section">
          <details class="admin-command-category admin-command-category--primary" open={selectedIntent.value !== ''}>
            <summary class="admin-command-category__summary">
              <span class="admin-command-category__heading">
                <h2>User Management</h2>
              </span>
            </summary>
            <div class="admin-command-category__content">
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
                {shouldShowForIntent(selectedIntent.value, ['add-user', 'manage-user']) && (
                  <AdminTask
                    title="Check user exists"
                    description="Use before reruns. Confirms identity visibility."
                    activeIntent={selectedIntent.value}
                    intents={['add-user', 'manage-user']}
                  >
                    <AdminCommand command={`kanidm person get ${userArg}`} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user']) && (
                  <AdminTask
                    title="Create Kanidm account"
                    description="Create account. Set primary email."
                    activeIntent={selectedIntent.value}
                    intents={['add-user']}
                  >
                    <AdminCommand command={`kanidm person create ${userArg} ${displayNameArg}`} />
                    <AdminCommand command={`kanidm person update ${userArg} --mail ${emailArg}`} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user']) && (
                  <AdminTask
                    title="Grant baseline access"
                    description="Enable Kanidm sign-in and normal user lookup."
                    activeIntent={selectedIntent.value}
                    intents={['add-user']}
                  >
                    <AdminCommand command={`kanidm group add-members users ${userArg}`} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user', 'manage-user']) && (
                  <AdminTask
                    title="Grant app/file/admin access"
                    description="Select groups. Copy generated command."
                    activeIntent={selectedIntent.value}
                    intents={['add-user', 'manage-user']}
                  >
                    {accessGroups.length > 0 ? (
                      <>
                        <div class="group-picker-section">
                          <h4>Unassigned</h4>
                          {unassignedAccessGroups.length > 0 ? (
                            <div class="group-picker">{unassignedAccessGroups.map((group) => renderGroupOption(group))}</div>
                          ) : (
                            <p>No unassigned groups for selected user.</p>
                          )}
                        </div>
                        <div class="group-picker-section">
                          <h4>Already assigned</h4>
                          {assignedAccessGroups.length > 0 ? (
                            <div class="group-picker">{assignedAccessGroups.map((group) => renderGroupOption(group))}</div>
                          ) : (
                            <p>No assigned groups for selected user.</p>
                          )}
                        </div>
                      </>
                    ) : (
                      <p>No non-protected groups are currently exposed from the configured Kanidm catalog.</p>
                    )}
                    <AdminCommand command={membershipCommand} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user', 'manage-secrets']) && (
                  <AdminTask
                    title="Vaultwarden signup"
                    description="User registers from browser on LAN or NetBird."
                    activeIntent={selectedIntent.value}
                    intents={['add-user', 'manage-secrets']}
                  >
                    <p>Have them open this URL and register with the same email used in Kanidm:</p>
                    <AdminCommand command={`https://passwords.${domain}/#/signup`} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user', 'manage-user', 'manage-secrets']) && (
                  <AdminTask
                    title="Create first sign-in link"
                    description="Generate short-lived Kanidm reset link. Share securely."
                    activeIntent={selectedIntent.value}
                    intents={['add-user', 'manage-user', 'manage-secrets']}
                  >
                    <AdminCommand command={`kanidm person credential create-reset-token ${userArg} 3600`} />
                  </AdminTask>
                )}
                {shouldShowForIntent(selectedIntent.value, ['add-user']) && (
                  <AdminTask
                    title="Hand off first sign-in"
                    description="Ask user to set password and MFA, open apps, save recovery details."
                    activeIntent={selectedIntent.value}
                    intents={['add-user']}
                  >
                    <p>Confirm user can sign in, open granted apps, and save recovery details.</p>
                  </AdminTask>
                )}
              </div>
            </div>
          </details>
        </section>
      )}
      <section class="section two-column">
        <div>
          <h2>Config And Deploys</h2>
          <ol class="steps">
            <li>Use vars.nix for host, network, storage, domain, and access.</li>
            <li>Use configuration.nix imports to enable or remove optional apps.</li>
            <li>Run guarded deploy test before switch.</li>
            <li>Keep generated secrets in agenix. Never commit plaintext.</li>
          </ol>
        </div>
        <div>
          <h2>User Support</h2>
          <ol class="steps">
            <li>Grant Kanidm groups before app access.</li>
            <li>Use commands above for account and group membership.</li>
            <li>Set phone Syncthing device ID before enabling phone backup.</li>
            <li>Use service pages after device IDs are known.</li>
          </ol>
        </div>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'For Admins | Sydney Basin Services',
};
