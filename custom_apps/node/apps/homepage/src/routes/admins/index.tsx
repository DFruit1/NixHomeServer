import { $, Slot, component$, useContext, useSignal } from '@builder.io/qwik';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { AdminStep } from '../../shared/types.js';
import { CanaryPanel } from '../../components/CanaryPanel.js';

const adminStepMetadata: Record<string, { category: 'network'; executionContext: string }> = {
  'Allow Jellyfin discovery replies with nftables': { category: 'network', executionContext: 'Linux client' },
  'Allow Jellyfin discovery replies with UFW': { category: 'network', executionContext: 'Linux client' },
  'Allow Jellyfin discovery replies with firewalld': { category: 'network', executionContext: 'Linux client' },
  'Allow Jellyfin discovery replies on Windows': { category: 'network', executionContext: 'Windows client (Administrator PowerShell)' },
  'Allow Jellyfin discovery on Apple devices': { category: 'network', executionContext: 'Apple client' },
};

const executionContext = (step: AdminStep): string => {
  const command = step.command;
  const metadata = adminStepMetadata[step.title];
  if (metadata) return metadata.executionContext;
  if (!command) return 'Guided steps';
  if (/^(?:sudo )?\.\//.test(command) || /^(?:git |nix (?:run|flake|eval)|DEPLOY_|\$EDITOR |find secrets)/.test(command)) {
    return 'Repository folder';
  }
  return 'Server terminal';
};

const matchesSearch = (query: string, values: (string | undefined)[]): boolean => {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  return normalizedQuery.length > 0 && values.some((value) => value?.toLocaleLowerCase().includes(normalizedQuery));
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
    context,
  }: {
    title: string;
    description: string;
    context: string;
  }) => (
    <details class="admin-task">
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
  const searchQuery = useSignal('');

  const setSearchQuery = $((event: Event) => {
    const input = event.target as HTMLInputElement;
    searchQuery.value = input.value;
  });

  const filteredSteps = searchQuery.value.trim().length > 0
    ? adminGuide.filter((step: AdminStep) => matchesSearch(searchQuery.value, [step.title, step.detail, step.command]))
    : adminGuide;

  return (
    <>
      {homepage.data?.user?.username === homepage.data?.canaryAdminUser && <CanaryPanel />}
      <section class="section admin-page">
        <header class="admin-page-header">
          <span class="eyebrow">Server administration</span>
          <h1>Admin tools</h1>
          <p>Commands and guidance generated from the deployed configuration. Command output is the source of truth for current runtime state.</p>
        </header>
        <div class="guide-callout">
          <p><strong>These commands can change the live server.</strong> Check where each runs and replace placeholders like SERVICE, USERNAME, and APP-GROUP before copying.</p>
        </div>
        <label class="admin-search">
          <span class="sr-only">Search commands</span>
          <input type="search" value={searchQuery.value} onInput$={setSearchQuery} placeholder="Search commands — e.g. deploy, backup, user, DNS" />
        </label>
        {filteredSteps.length > 0 ? (
          <div class="admin-task-list">
            {filteredSteps.map((step: AdminStep) => (
              <AdminTask
                title={step.title}
                description={step.detail}
                context={executionContext(step)}
                key={step.title}
              >
                {step.command && <AdminCommand command={step.command} />}
              </AdminTask>
            ))}
          </div>
        ) : (
          <p class="admin-search-empty">
            {searchQuery.value.trim().length > 0 ? 'No commands match your search.' : 'No admin commands are available in the current configuration.'}
          </p>
        )}
      </section>
    </>
  );
});
