import { $, Slot, component$, useContext, useSignal } from '@builder.io/qwik';
import { HomepageContext } from '../../shared/homepage-context.js';
import {
  buildMembershipCommands,
  configuredMembershipEdit,
  configuredMembershipEffect,
  configuredMembershipSelections,
  type AccessChangeAction,
} from '../../shared/admin-access.js';
import type { AdminStep } from '../../shared/types.js';
import { CanaryPanel } from '../../components/CanaryPanel.js';

type AdminCategoryId = 'server' | 'apps' | 'identity' | 'storageBackups' | 'network';
type AdminIntentId = 'add-user' | 'manage-user' | 'manage-secrets';
type AdminModeId = AdminIntentId | 'other';

type AdminStepMeta = {
  category: AdminCategoryId;
  intents?: AdminIntentId[];
  displayTitle?: string;
};

const adminCategories: { id: AdminCategoryId; title: string; description: string }[] = [
  {
    id: 'server',
    title: 'Server health',
    description: 'Check the server before a change or when something is not working.',
  },
  {
    id: 'apps',
    title: 'Deployments and apps',
    description: 'Check and deploy repository changes, inspect app services, and apply managed configuration.',
  },
  {
    id: 'identity',
    title: 'User accounts and access',
    description: 'Add users, change app access, recover accounts, and update Kanidm-managed access.',
  },
  {
    id: 'storageBackups',
    title: 'Storage & Backups',
    description: 'Disk health, filesystems, ZFS pool checks, Kopia snapshots, and offsite sync.',
  },
  {
    id: 'network',
    title: 'Network and external access',
    description: 'Check web routing, private DNS, the Cloudflare tunnel, NetBird, and firewall rules.',
  },
];

const adminStepMeta: Record<string, AdminStepMeta> = {
  'Review evaluated config': { category: 'server', displayTitle: 'Review the generated configuration' },
  'Validate config readiness': { category: 'server', displayTitle: 'Check configuration and deployment requirements' },
  'Export operations inventory': { category: 'server', displayTitle: 'Export the server inventory' },
  'Check git worktree': { category: 'server', displayTitle: 'Check local Git changes' },
  'Check service health': { category: 'server' },
  'List scheduled timers': { category: 'server' },
  'Review current boot warnings': { category: 'server' },
  'Show resource snapshot': { category: 'server', displayTitle: 'Show overall server status' },
  'Validate broad changes': { category: 'apps', displayTitle: 'Test a large change' },
  'Run lean repo validation': { category: 'apps', displayTitle: 'Run quick repository checks' },
  'Run full repo validation': { category: 'apps', displayTitle: 'Run all repository checks' },
  'Evaluate flake without building': { category: 'apps' },
  'Dry-run deploy target resolution': { category: 'apps', displayTitle: 'Preview the deployment command' },
  'Run routine guarded deploy': { category: 'apps', displayTitle: 'Test a deployment on the server' },
  'Run guarded deploy with local build': { category: 'apps', displayTitle: 'Test a deployment built on this computer' },
  'Switch after a passing test': { category: 'apps', displayTitle: 'Make a tested deployment permanent' },
  'Show generations for rollback': { category: 'apps', displayTitle: 'List system versions available for rollback' },
  'Emergency rollback current generation': { category: 'apps', displayTitle: 'Emergency rollback to the previous system version' },
  'Check app service status': { category: 'apps' },
  'Follow app logs': { category: 'apps' },
  'Restart a single app service': { category: 'apps' },
  'Restart homepage': { category: 'apps' },
  'Check OAuth proxy logs': { category: 'apps' },
  'List storage layout services': { category: 'apps' },
  'Re-run Immich OIDC reconcile': { category: 'apps', displayTitle: 'Update Immich accounts from Kanidm' },
  'Re-run Paperless OIDC reconcile': { category: 'apps', displayTitle: 'Update Paperless accounts from Kanidm' },
  'Retrieve Jellyfin initial password': { category: 'apps', intents: ['add-user', 'manage-user'], displayTitle: 'Give a user their initial Jellyfin password' },
  'Re-run Jellyfin library sync': { category: 'apps' },
  'Re-run Kiwix library sync': { category: 'apps' },
  'Check Kanidm health': { category: 'identity' },
  'Bootstrap or recover operator credential': { category: 'identity', intents: ['manage-secrets'] },
  'Authenticate Kanidm CLI': { category: 'identity' },
  'List Kanidm people': { category: 'identity', intents: ['manage-user'] },
  'List Kanidm groups': { category: 'identity' },
  'Inspect Kanidm group': { category: 'identity', intents: ['manage-user'] },
  'Remove user from access group': { category: 'identity', intents: ['manage-user'] },
  'Revoke offline-media device access': { category: 'identity', intents: ['manage-user'] },
  'Restart identity reconciliation': { category: 'identity', displayTitle: 'Apply Kanidm account and file-access changes' },
  'Manage Kanidm entity removal explicitly': { category: 'identity', intents: ['manage-user'], displayTitle: 'Remove a managed Kanidm user or group' },
  'Show mounted filesystems': { category: 'storageBackups' },
  'Show disk layout': { category: 'storageBackups' },
  'Discover monitored storage devices': { category: 'storageBackups' },
  'Check ZFS pool status': { category: 'storageBackups' },
  'Start ZFS scrub': { category: 'storageBackups' },
  'Show Btrfs filesystem usage': { category: 'storageBackups' },
  'Check Btrfs scrub status': { category: 'storageBackups' },
  'Run SMART short sweep': { category: 'storageBackups' },
  'Inspect a disk with SMART': { category: 'storageBackups' },
  'Check storage monitor logs': { category: 'storageBackups' },
  'Check backup timers': { category: 'storageBackups' },
  'Check Kopia services': { category: 'storageBackups' },
  'Run persist snapshot now': { category: 'storageBackups' },
  'Inspect persist snapshot logs': { category: 'storageBackups' },
  'Run offsite Kopia sync now': { category: 'storageBackups' },
  'Inspect offsite sync logs': { category: 'storageBackups' },
  'Check backup repository size': { category: 'storageBackups' },
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
  'Show SFTP host key fingerprint': { category: 'network' },
  'Rotate or regenerate secrets': { category: 'server', intents: ['manage-secrets'], displayTitle: 'Create or replace encrypted secrets' },
  'List encrypted secrets': { category: 'server', intents: ['manage-secrets'] },
  'List expected external secrets': { category: 'server', intents: ['manage-secrets'] },
  'Edit staged external secret': { category: 'server', intents: ['manage-secrets'], displayTitle: 'Edit a plaintext secret before encryption' },
  'Encrypt staged external secrets': { category: 'server', intents: ['manage-secrets'], displayTitle: 'Encrypt one staged external secret' },
};

const fallbackStepMeta: AdminStepMeta = { category: 'server' };

const metaForStep = (step: AdminStep): AdminStepMeta => adminStepMeta[step.title] ?? fallbackStepMeta;
const titleForStep = (step: AdminStep): string => metaForStep(step).displayTitle ?? step.title;

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

const adminIntents: { id: AdminModeId; label: string }[] = [
  { id: 'add-user', label: 'Add a user' },
  { id: 'manage-user', label: "Change a user's access" },
  { id: 'manage-secrets', label: 'Recover an account or manage secrets' },
  { id: 'other', label: 'Search all commands' },
];

const isAdminIntent = (mode: AdminModeId | ''): mode is AdminIntentId =>
  mode === 'add-user' || mode === 'manage-user' || mode === 'manage-secrets';

const isIntentOpen = (activeIntent: AdminIntentId | '', intents: AdminIntentId[] = []): boolean =>
  activeIntent !== '' && intents.includes(activeIntent);

const shouldShowForIntent = (activeIntent: AdminIntentId | '', intents: AdminIntentId[] = []): boolean =>
  activeIntent === '' || intents.includes(activeIntent);

const matchesSearch = (query: string, values: (string | undefined)[]): boolean => {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  return normalizedQuery.length > 0 && values.some((value) => value?.toLocaleLowerCase().includes(normalizedQuery));
};

const executionContext = (command: string | undefined): string => {
  if (!command) return 'Guided steps';
  if (/^(?:sudo )?\.\//.test(command) || /^(?:git |nix (?:run|flake|eval)|DEPLOY_|\$EDITOR |find secrets)/.test(command)) {
    return 'Repository folder';
  }
  return 'Server terminal';
};

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
    context,
    forceOpen = false,
    intents = [],
  }: {
    title: string;
    description: string;
    activeIntent: AdminIntentId | '';
    context: string;
    forceOpen?: boolean;
    intents?: AdminIntentId[];
  }) => (
    <details class="admin-task" open={forceOpen || isIntentOpen(activeIntent, intents)}>
      <summary class="admin-task__summary">
        <span class="admin-task__main">
          <span class="admin-task__title">{title}</span>
          <span class="admin-task__context">{context}</span>
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
  if (!homepage.data?.isAdmin) {
    return (
      <section class="section">
        <div class="empty-state">
          <h2>Administrator access required</h2>
          <p>This handbook is available only to the configured server operator.</p>
        </div>
      </section>
    );
  }
  const adminGuide = homepage.data?.adminGuide ?? [];
  const domain = homepage.data?.domain ?? 'example.test';
  const currentUser = homepage.data?.user;
  const operatorArg = shellSingleQuote(homepage.data?.canaryAdminUser?.trim() || 'idm_admin');
  const username = useSignal('');
  const email = useSignal('');
  const selectedMode = useSignal<AdminModeId | ''>('');
  const searchQuery = useSignal('');
  const groupDescriptions = homepage.data?.kanidmGroupDescriptions ?? {};
  const groupManagement = homepage.data?.kanidmGroupManagement ?? {};
  const passwordsEnabled = homepage.data?.services.some((service) => service.id === 'passwords' && service.enabled) ?? false;
  const accessGroups = (homepage.data?.kanidmGroups ?? [])
    .filter((group) => !isProtectedGroup(group))
    .sort((a, b) => a.localeCompare(b));
  const appBundleAccessGroups = accessGroups.filter((group) => groupManagement[group] === 'identity.appUsers');
  const selectedGroups = useSignal<string[]>([]);
  const accessAction = useSignal<AccessChangeAction>('grant');

  const userArg = buildUserArg(username.value);
  const emailArg = buildEmailArg(email.value);
  const displayNameArg = buildDisplayNameArg(username.value);

  const liveManagedGroups = selectedGroups.value.filter((group) => !groupManagement[group] || groupManagement[group] === 'manual');
  const configuredGroups = selectedGroups.value.filter((group) => groupManagement[group] && groupManagement[group] !== 'manual');
  const membershipCommand = buildMembershipCommands(liveManagedGroups, userArg, accessAction.value).join('\n');
  const managedMemberships = configuredMembershipSelections(configuredGroups, groupManagement);
  const configuredMemberValue = JSON.stringify(username.value.trim() || '<username>');
  const adminSections = groupedAdminSteps(adminGuide);
  const activeIntent: AdminIntentId | '' = isAdminIntent(selectedMode.value) ? selectedMode.value : '';
  const hasSelectedMode = selectedMode.value !== '';
  const searchIsActive = selectedMode.value === 'other';
  const userTaskSearchMatches = {
    checkUser: matchesSearch(searchQuery.value, ['Find user account', 'Check that the Kanidm user exists before creating the account or changing its sign-in methods.', `kanidm person get ${userArg}`]),
    createAccount: matchesSearch(searchQuery.value, [
      'Create user in Kanidm',
      'Create the user and save the main email address that apps will use. Create the first sign-in link in a later step.',
      `kanidm person create ${userArg} ${displayNameArg}`,
      `kanidm person update ${userArg} --mail ${emailArg}`,
    ]),
    grantBaseline: matchesSearch(searchQuery.value, [
      'Allow standard sign-in',
      'Add the user to the standard users group so they can sign in and apps can find their account.',
      `kanidm group add-members users ${userArg}`,
    ]),
    grantAccess: matchesSearch(searchQuery.value, [
      'Choose app and admin access',
      'Select the groups that control apps, files, backups, and admin tools. Some apps need an account update before the change appears.',
      membershipCommand,
      accessGroups.join(' '),
    ]),
    vaultwardenSignup: passwordsEnabled && matchesSearch(searchQuery.value, [
      'Create Passwords account',
      'Ask the user to register in the Passwords app with their Kanidm email address. They must create and save a separate master password.',
      `https://passwords.${domain}/#/signup`,
    ]),
    signInLink: matchesSearch(searchQuery.value, [
      'Create account recovery link',
      'Generate a single-use Kanidm link that is valid for one hour. The user opens it to set a password and review other sign-in methods.',
      `kanidm person credential create-reset-token ${userArg} --name ${operatorArg}`,
    ]),
    handoff: matchesSearch(searchQuery.value, [
      'Help user finish setup',
      'Ask the user to set a password and second sign-in method, open their apps, and save recovery details.',
      'Confirm the user can sign in, open their apps, add a second sign-in method, save recovery details, and see the expected apps on the homepage.',
    ]),
  };
  const hasMatchingUserTasks = Object.values(userTaskSearchMatches).some(Boolean);
  const showUserManagement = searchIsActive
    ? hasMatchingUserTasks
    : activeIntent === '' || ['add-user', 'manage-user', 'manage-secrets'].includes(activeIntent);
  const showCheckUser = searchIsActive ? userTaskSearchMatches.checkUser : shouldShowForIntent(activeIntent, ['add-user', 'manage-user']);
  const showCreateAccount = searchIsActive ? userTaskSearchMatches.createAccount : shouldShowForIntent(activeIntent, ['add-user']);
  const showGrantBaseline = searchIsActive ? userTaskSearchMatches.grantBaseline : shouldShowForIntent(activeIntent, ['add-user']);
  const showGrantAccess = searchIsActive ? userTaskSearchMatches.grantAccess : shouldShowForIntent(activeIntent, ['add-user', 'manage-user']);
  const showVaultwardenSignup = passwordsEnabled
    && (searchIsActive ? userTaskSearchMatches.vaultwardenSignup : shouldShowForIntent(activeIntent, ['add-user', 'manage-secrets']));
  const showVaultwardenUnavailable = !passwordsEnabled
    && !searchIsActive
    && shouldShowForIntent(activeIntent, ['add-user', 'manage-secrets']);
  const showSignInLink = searchIsActive
    ? userTaskSearchMatches.signInLink
    : shouldShowForIntent(activeIntent, ['add-user', 'manage-user', 'manage-secrets']);
  const showHandoff = searchIsActive ? userTaskSearchMatches.handoff : shouldShowForIntent(activeIntent, ['add-user']);
  const visibleAdminSections = (hasSelectedMode ? adminSections : [])
    .map((section) => ({
      ...section,
      steps: searchIsActive
        ? section.steps.filter((step) => matchesSearch(searchQuery.value, [step.title, titleForStep(step), step.detail, step.command]))
        : activeIntent
          ? section.steps.filter((step) => shouldShowForIntent(activeIntent, metaForStep(step).intents))
        : section.steps,
    }))
    .filter((section) => section.steps.length > 0 || (section.id === 'identity' && showUserManagement));
  const typedUsername = username.value.trim();
  const membershipIsKnown = Boolean(currentUser && typedUsername === currentUser.username);
  const targetIsConfiguredOperator = Boolean(
    homepage.data?.canaryAdminUser && typedUsername === homepage.data.canaryAdminUser,
  );
  const typedUserGroups = membershipIsKnown ? currentUser?.groups ?? [] : [];
  const unassignedAccessGroups = membershipIsKnown ? accessGroups.filter((group) => !typedUserGroups.includes(group)) : accessGroups;
  const assignedAccessGroups = membershipIsKnown ? accessGroups.filter((group) => typedUserGroups.includes(group)) : [];
  const candidateAccessGroups = membershipIsKnown
    ? accessAction.value === 'grant' ? unassignedAccessGroups : assignedAccessGroups
    : accessGroups;
  const actionableAccessGroups = accessAction.value === 'revoke' && targetIsConfiguredOperator
    ? candidateAccessGroups.filter((group) => group === 'app-admin'
      ? false
      : !groupManagement[group] || groupManagement[group] === 'manual')
    : candidateAccessGroups;

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
    const isAppBundleGroup = groupManagement[group] === 'identity.appUsers';
    const affectedGroups = accessAction.value === 'grant'
      ? group === 'app-admin'
        ? ['app-admin', ...appBundleAccessGroups]
        : isAppBundleGroup
          ? [...appBundleAccessGroups, ...(!input.checked && selectedGroups.value.includes('app-admin') ? ['app-admin'] : [])]
          : [group]
      : isAppBundleGroup
        ? [...appBundleAccessGroups, 'app-admin']
        : [group];
    selectedGroups.value = input.checked
      ? [...new Set([...selectedGroups.value, ...affectedGroups])].sort()
      : selectedGroups.value.filter((current) => !affectedGroups.includes(current));
  });

  const selectAccessAction = $((action: AccessChangeAction) => {
    accessAction.value = action;
    selectedGroups.value = [];
  });

  const selectMode = $((mode: AdminModeId) => {
    selectedMode.value = selectedMode.value === mode ? '' : mode;
    if (mode !== 'other') {
      searchQuery.value = '';
    }
  });

  const setSearchQuery = $((event: Event) => {
    const input = event.target as HTMLInputElement;
    searchQuery.value = input.value;
  });

  const renderGroupOption = (group: string) => (
    <label key={group} class="group-picker__option">
      <input type="checkbox" checked={selectedGroups.value.includes(group)} onChange$={(event) => toggleGroup(group, event)} />
      <span class="group-name" title={groupDescriptions[group] ?? 'No description available'}>
        {group}
      </span>
      {groupManagement[group] && groupManagement[group] !== 'manual' && <small>{groupManagement[group]}</small>}
    </label>
  );

  return (
    <>
      {currentUser?.username === homepage.data?.canaryAdminUser && <CanaryPanel />}
      <section class="section admin-page">
        <header class="admin-page-header">
          <span class="eyebrow">Server administration</span>
          <h1>Admin tools</h1>
          <p>Choose a task to see the relevant steps, or search all commands. Each command shows where to run it and what it does.</p>
        </header>
        <details class="admin-safety-guide">
          <summary>
            <span>
              <strong>Inspect before changing anything</strong>
              <small>These commands can change the live server. Check where each command runs and replace example values before you copy it.</small>
            </span>
          </summary>
          <div>
            <p><strong>Test before switching.</strong> Run the deployment test first. Check failed systemd units before making the new version permanent.</p>
            <p><strong>Change one thing at a time.</strong> Start with service status and logs, then change only the affected service.</p>
            <p><strong>Replace example values.</strong> APP, USERNAME, and disk IDs must refer to the real service, user, or disk.</p>
          </div>
        </details>
        <div class={{ 'admin-intent-hero': true, 'is-compact': hasSelectedMode }}>
          <div class="admin-intent-heading">
            <span class="eyebrow">Start with an outcome</span>
            <h2 aria-hidden={activeIntent !== ''}>What do you need to do?</h2>
          </div>
          <div class="admin-intent-actions" role="group" aria-label="Common admin tasks">
            {adminIntents.map((intent) => (
              <button
                type="button"
                class={{ selected: selectedMode.value === intent.id }}
                aria-pressed={selectedMode.value === intent.id}
                onClick$={() => selectMode(intent.id)}
                key={intent.id}
              >
                {intent.label}
              </button>
            ))}
          </div>
          {searchIsActive && (
            <label class="admin-search">
              <span>Search all admin commands</span>
              <input type="search" value={searchQuery.value} onInput$={setSearchQuery} placeholder="For example: failed service, deploy, backup, DNS, user" />
            </label>
          )}
        </div>
        {!hasSelectedMode && <p class="admin-selection-hint">Choose a task to see its checklist.</p>}
        {searchIsActive && searchQuery.value.trim() === '' && <p class="admin-selection-hint">Search for a service, problem, or action.</p>}
        {visibleAdminSections.length > 0 && (
          <div class="admin-command-layout">
            {visibleAdminSections.map((section) => (
              <details class="admin-command-category" open={activeIntent !== '' || searchIsActive} key={section.id}>
                <summary class="admin-command-category__summary">
                  <span class="admin-command-category__heading">
                    <h3>{section.title}</h3>
                    <p>{section.description}</p>
                  </span>
                </summary>
                {section.steps.length > 0 && (
                  <div class="admin-task-list">
                    {section.steps.map((step) => (
                      <AdminTask
                        title={titleForStep(step)}
                        description={step.detail}
                        activeIntent={activeIntent}
                        context={executionContext(step.command)}
                        forceOpen={searchIsActive}
                        intents={metaForStep(step).intents}
                        key={step.title}
                      >
                        {step.command && <AdminCommand command={step.command} />}
                      </AdminTask>
                    ))}
                  </div>
                )}
                {section.id === 'identity' && showUserManagement && (
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
                        Use my account details
                      </button>
                    </div>
                    <div class="admin-task-list">
                      {showCheckUser && (
                        <AdminTask
                          title="Find user account"
                          description="Check that the Kanidm user exists before creating the account or changing its sign-in methods."
                          activeIntent={activeIntent}
                          context="Admin terminal"
                          forceOpen={searchIsActive}
                          intents={['add-user', 'manage-user']}
                        >
                          <AdminCommand command={`kanidm person get ${userArg}`} />
                        </AdminTask>
                      )}
                      {showCreateAccount && (
                        <AdminTask
                          title="Create user in Kanidm"
                          description="Create the user and save the main email address that apps will use. Create the first sign-in link in a later step."
                          activeIntent={activeIntent}
                          context="Admin terminal"
                          forceOpen={searchIsActive}
                          intents={['add-user']}
                        >
                          <AdminCommand command={`kanidm person create ${userArg} ${displayNameArg}`} />
                          <AdminCommand command={`kanidm person update ${userArg} --mail ${emailArg}`} />
                        </AdminTask>
                      )}
                      {showGrantBaseline && (
                        <AdminTask
                          title="Allow standard sign-in"
                          description="Add the user to the standard users group so they can sign in and apps can find their account."
                          activeIntent={activeIntent}
                          context="Admin terminal"
                          forceOpen={searchIsActive}
                          intents={['add-user']}
                        >
                          <AdminCommand command={`kanidm group add-members users ${userArg}`} />
                        </AdminTask>
                      )}
                      {showGrantAccess && (
                        <AdminTask
                          title="Choose app and admin access"
                          description="Choose whether to grant or revoke access, then select the groups involved. Homepage separates live manual groups from memberships that must be changed in vars.nix."
                          activeIntent={activeIntent}
                          context="Admin terminal"
                          forceOpen={searchIsActive}
                          intents={['add-user', 'manage-user']}
                        >
                          <div class="admin-intent-actions access-action-selector" role="group" aria-label="Access change action">
                            <button
                              type="button"
                              class={{ selected: accessAction.value === 'grant' }}
                              aria-pressed={accessAction.value === 'grant'}
                              onClick$={() => selectAccessAction('grant')}
                            >
                              Grant access
                            </button>
                            <button
                              type="button"
                              class={{ selected: accessAction.value === 'revoke' }}
                              aria-pressed={accessAction.value === 'revoke'}
                              onClick$={() => selectAccessAction('revoke')}
                            >
                              Revoke access
                            </button>
                          </div>
                          {accessGroups.length > 0 ? (
                            <>
                              {appBundleAccessGroups.length > 0 && (
                                <p class="hint"><strong>Default app bundle:</strong> groups marked <code>identity.appUsers</code> cannot be changed independently by this configuration. Selecting any one selects the whole enabled-app bundle. This grants every enabled default app group above, not only one app. Granting <code>app-admin</code> also grants that bundle; revoking the bundle also revokes <code>app-admin</code> so an administrator is not left without access to the apps they manage.</p>
                              )}
                              <div class="group-picker-section">
                                <h4>{membershipIsKnown
                                  ? accessAction.value === 'grant' ? 'Not assigned' : 'Currently assigned'
                                  : accessAction.value === 'grant' ? 'Access to grant' : 'Access to revoke'}</h4>
                                {actionableAccessGroups.length > 0 ? (
                                  <div class="group-picker">{actionableAccessGroups.map((group) => renderGroupOption(group))}</div>
                                ) : (
                                  <p>{accessAction.value === 'grant'
                                    ? 'This user already has every available group.'
                                    : 'This user does not have any of these groups.'}</p>
                                )}
                              </div>
                              {!membershipIsKnown && <p class="hint">Homepage does not query live membership for another person. Run the “Find user account” command first and verify the current groups in Kanidm before changing access. Never revoke a group merely because it appears in this evaluated catalog.</p>}
                              {accessAction.value === 'revoke' && targetIsConfiguredOperator && (
                                <div class="guide-callout">
                                  <strong>The configured operator has inherited access</strong>
                                  <p><code>identity.adminUser</code> deliberately inherits the default app bundle, <code>app-admin</code>, and both backup roles. Those groups are hidden from this revocation picker because removing the operator from the ordinary user lists will not revoke them. Treat changing the operator as a planned identity migration, not routine access removal.</p>
                                </div>
                              )}
                            </>
                          ) : (
                            <p>No app or admin access groups are available in the current Kanidm configuration.</p>
                          )}
                          {membershipCommand && (
                            <>
                              <p class="hint"><strong>Manual/additive membership:</strong> run this {accessAction.value === 'grant' ? 'grant' : 'revocation'} command in an authenticated admin terminal. {accessAction.value === 'grant'
                                ? 'Extra members are preserved when this additive group is provisioned again.'
                                : <>Before relying on the revocation, search <code>vars.nix</code> for the username: a member seeded by configuration must also be removed from its source list and deployed, or provisioning can add it again.</>}</p>
                              <AdminCommand command={membershipCommand} />
                              <p class="hint">Run <code>kanidm person get {userArg}</code> afterward and have the user sign out and back in before checking the result.</p>
                            </>
                          )}
                          {managedMemberships.length > 0 && (
                            <div class="guide-callout neutral">
                              <strong>Repository-managed access: edit before deploying</strong>
                              <p>These memberships come from configuration and cannot be changed by a Kanidm command alone.</p>
                              <ol>
                                {managedMemberships.map((selection) => (
                                  <li key={selection.source}>
                                    In <code>vars.nix</code>, {configuredMembershipEdit(selection.source, accessAction.value, configuredMemberValue)}.
                                    {' '}This controls <code>{selection.groups.join(' ')}</code>. {configuredMembershipEffect(selection.source, accessAction.value)}
                                  </li>
                                ))}
                                <li>Review the edited list for duplicate or unintended users, then save and validate <code>vars.nix</code>.</li>
                                <li>Run <code>./scripts/deploy.sh --action test</code> from the repository folder. A live Kanidm command alone will be overwritten for these groups.</li>
                                <li>After the deploy passes, run <code>kanidm person get {userArg}</code>, then have the user sign out and back in before testing access.</li>
                              </ol>
                            </div>
                          )}
                          {!membershipCommand && managedMemberships.length === 0 && (
                            <p class="hint">Choose one or more groups above to generate the appropriate {accessAction.value === 'grant' ? 'grant' : 'revocation'} command or configuration checklist.</p>
                          )}
                        </AdminTask>
                      )}
                      {showVaultwardenSignup && (
                        <AdminTask
                          title="Create Passwords account"
                          description="Ask the user to register in the Passwords app with their Kanidm email address. They must create and save a separate master password."
                          activeIntent={activeIntent}
                          context="User instructions"
                          forceOpen={searchIsActive}
                          intents={['add-user', 'manage-secrets']}
                        >
                          <p>Have them open this URL and register with the same email used in Kanidm:</p>
                          <AdminCommand command={`https://passwords.${domain}/#/signup`} />
                        </AdminTask>
                      )}
                      {showVaultwardenUnavailable && (
                        <div class="guide-callout neutral">
                          <strong>Passwords account step unavailable</strong>
                          <p>The Passwords service is disabled in this server configuration. Skip its signup step unless an administrator enables and deploys Vaultwarden first.</p>
                        </div>
                      )}
                      {showSignInLink && (
                        <AdminTask
                          title="Create account recovery link"
                          description="Generate a single-use Kanidm link that is valid for one hour. The user opens it to set a password and review other sign-in methods."
                          activeIntent={activeIntent}
                          context="Admin terminal"
                          forceOpen={searchIsActive}
                          intents={['add-user', 'manage-user', 'manage-secrets']}
                        >
                          <AdminCommand command={`kanidm person credential create-reset-token ${userArg} --name ${operatorArg}`} />
                          <p>Send the generated URL to the user through a trusted channel. The link is single-use and should not be posted in tickets or shared logs.</p>
                        </AdminTask>
                      )}
                      {showHandoff && (
                        <AdminTask
                          title="Help user finish setup"
                          description="Ask the user to set a password and second sign-in method, open their apps, and save recovery details."
                          activeIntent={activeIntent}
                          context="User instructions"
                          forceOpen={searchIsActive}
                          intents={['add-user']}
                        >
                          <p>Confirm the user can sign in, open their apps, add a second sign-in method, save recovery details, and see the expected apps on the homepage.</p>
                        </AdminTask>
                      )}
                    </div>
                  </div>
                )}
              </details>
            ))}
          </div>
        )}
        {searchIsActive && searchQuery.value.trim() !== '' && visibleAdminSections.length === 0 && <p class="admin-search-empty">No commands match your search.</p>}
      </section>
    </>
  );
});
