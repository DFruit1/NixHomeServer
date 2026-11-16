import { $, component$, useContext, useSignal } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { BuildModeCard } from '../../components/BuildModeCard.js';
import { CanaryPanel } from '../../components/CanaryPanel.js';
import { PowerScheduleCard } from '../../components/PowerScheduleCard.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { AdminStep } from '../../shared/types.js';

/**
 * The runbooks the page is organised around. Commands arrive from the server
 * configuration already tagged with one of these ids and with where they run;
 * `ordered` sections are procedures whose commands are meant to be run in order.
 */
const adminSections: Array<{ id: string; title: string; intro: string; ordered?: boolean }> = [
  {
    id: 'deploy',
    title: 'Deploy a change',
    ordered: true,
    intro: 'Run in order. Test activates changes on the live server; rebooting restores the boot default. Switch only after a matching green test.',
  },
  {
    id: 'recover',
    title: 'Undo a bad deploy',
    intro: 'Run at the server console, not over SSH, to leave a bad generation.',
  },
  {
    id: 'health',
    title: 'Find and fix a failing service',
    ordered: true,
    intro: 'Find the failure, read its log, then restart the affected service.',
  },
  {
    id: 'people',
    title: 'Add a person or change their access',
    ordered: true,
    intro: 'Manage accounts and access groups in Kanidm. Ask the person to sign out and back in after access changes.',
  },
  {
    id: 'apps',
    title: 'Sync an app with Kanidm or its library',
    intro: 'Run one of these when an app has not picked up an access change or new files by itself.',
  },
  {
    id: 'jellyfin-discovery',
    title: 'Jellyfin apps cannot find the server',
    intro: 'Discovery replies leave the server from UDP port 7359 and are often dropped by the client’s own firewall. These are run on the client device, not on the server.',
  },
  {
    id: 'storage',
    title: 'Storage and backups',
    intro: 'Backup freshness and dump verification are on the Dashboard. Use these to look closer or to start a run by hand.',
  },
  {
    id: 'network',
    title: 'Network and reverse proxy',
    intro: 'Check these when a service is running but cannot be reached.',
  },
];

const otherSection: (typeof adminSections)[number] = { id: 'other', title: 'Other commands', intro: '' };

const placeholderPattern = /(\bUSERNAME\b|\bSERVICE\b|\bAPP-GROUP\b|\bEMAIL\b|<[A-Z_]+>|'Display Name'|\/path\/to\/age\.key)/;

const matchesSearch = (query: string, step: AdminStep): boolean => {
  const needle = query.trim().toLocaleLowerCase();
  return [step.title, step.detail, step.command].some((value) => value?.toLocaleLowerCase().includes(needle));
};

const AdminCommand = component$(({ command, runsOn }: { command: string; runsOn?: string }) => {
  const copied = useSignal(false);

  const copyCommand = $(async () => {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      return;
    }
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, 1600);
  });

  return (
    <div class="ops-code">
      <div class="ops-code__bar">
        <span>{runsOn ?? 'Server terminal'}</span>
        <button type="button" aria-label={copied.value ? 'Copied command' : 'Copy command'} onClick$={copyCommand}>
          {copied.value ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre><code>
        {command.split(placeholderPattern).map((part, index) => (
          index % 2 === 1 ? <mark key={index}>{part}</mark> : part
        ))}
      </code></pre>
    </div>
  );
});

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const searchQuery = useSignal('');
  const data = homepage.data;

  if (!data?.isAdmin) {
    return (
      <section class="section">
        <div class="empty-state">
          <h2>Administrator access required</h2>
          <p>This handbook is available only to the configured server operator.</p>
        </div>
      </section>
    );
  }

  const adminGuide = data.adminGuide ?? [];
  const needle = searchQuery.value.trim().toLocaleLowerCase();
  const searching = needle.length > 0;
  const knownIds = new Set(adminSections.map((section) => section.id));
  const sections = [...adminSections, otherSection]
    .map((section) => ({
      ...section,
      steps: adminGuide.filter((step) => {
        const belongs = section.id === 'other'
          ? !step.section || !knownIds.has(step.section)
          : step.section === section.id;
        return belongs && (!searching || matchesSearch(needle, step) || section.title.toLocaleLowerCase().includes(needle));
      }),
    }))
    .filter((section) => section.steps.length > 0);

  const matchesControl = (text: string) => !searching || text.toLocaleLowerCase().includes(needle);
  const showCanary = data.user.username === data.canaryAdminUser && matchesControl('Server controls Service access canary Run service checks sign-in');
  const showPower = data.powerScheduleAvailable && matchesControl('Server controls Power schedule sleep suspend wake');
  const showBuild = data.buildModeAvailable && matchesControl('Server controls Nix build mode allocation deploy');
  const hasControls = showCanary || showPower || showBuild;
  const groups = data.kanidmGroups ?? [];

  return (
    <section class="doc ops">
      <header class="doc-head">
        <h1>For admins</h1>
        <p class="doc-lead">
          Commands and server controls.{' '}
          {data.adminDashboardAvailable && <>View health on the <Link href="/admin-dashboard">Dashboard</Link>.</>}
        </p>
      </header>

      <div class="ops-layout">
        <nav class="ops-nav" aria-label="Admin sections">
          <ul>
            {hasControls && <li><a href="#ops-controls">Server controls</a></li>}
            {sections.map((section) => (
              <li key={section.id}><a href={`#ops-${section.id}`}>{section.title}</a></li>
            ))}
          </ul>
        </nav>

        <div class="ops-body">
          <div class="ops-search">
            <input
              type="search"
              aria-label="Search commands and controls"
              value={searchQuery.value}
              onInput$={(_, target) => {
                searchQuery.value = target.value;
              }}
              placeholder="Search commands and controls"
            />
            {searching && (
              <button type="button" class="doc-btn doc-btn--quiet" onClick$={() => { searchQuery.value = ''; }}>Clear search</button>
            )}
            <p class="doc-warn">
              <strong>These commands can change the live server.</strong> Replace highlighted placeholders such as <mark>USERNAME</mark> before running one.
            </p>
          </div>

          {searching && sections.length > 0 && (
            <p class="doc-note">Showing matching commands. Clear search to see each full runbook before running a procedure.</p>
          )}

          {hasControls && (
            <section id="ops-controls" class="ops-section" aria-labelledby="ops-controls-heading">
              <h2 id="ops-controls-heading">Server controls</h2>
              {showCanary && <CanaryPanel />}
              {showPower && <PowerScheduleCard />}
              {showBuild && <BuildModeCard />}
            </section>
          )}

          {sections.map((section) => (
            <section key={section.id} id={`ops-${section.id}`} class="ops-section" aria-labelledby={`ops-${section.id}-heading`}>
              <h2 id={`ops-${section.id}-heading`}>{section.title}</h2>
              {section.intro && <p class="ops-section__intro">{section.intro}</p>}
              <ol class={{ 'ops-cmds': true, 'ops-cmds--ordered': Boolean(section.ordered) && !searching }}>
                {section.steps.map((step) => (
                  <li key={step.title} class="ops-cmd">
                    <div class="ops-cmd__text">
                      <h3>{step.title}</h3>
                      <p>{step.detail}</p>
                    </div>
                    {step.command && <AdminCommand command={step.command} runsOn={step.runsOn} />}
                  </li>
                ))}
              </ol>

              {section.id === 'people' && !searching && groups.length > 0 && (
                <details class="doc-more ops-groups">
                  <summary>Groups you can grant ({groups.length})</summary>
                  <div class="ops-groups__scroll">
                    <table>
                      <thead>
                        <tr>
                          <th scope="col">Group</th>
                          <th scope="col">Grants</th>
                          <th scope="col">Membership is set</th>
                        </tr>
                      </thead>
                      <tbody>
                        {groups.map((group) => (
                          <tr key={group}>
                            <th scope="row"><code>{group}</code></th>
                            <td>{data.kanidmGroupDescriptions?.[group]}</td>
                            <td>
                              {data.kanidmGroupManagement?.[group] === 'identity.appUsers'
                                ? <>In <code>vars.nix</code>, then deployed. A manual grant is overwritten.</>
                                : data.kanidmGroupManagement?.[group] === 'manual'
                                  ? 'With the commands above. A deploy keeps it.'
                                  : 'Unknown'}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </details>
              )}
            </section>
          ))}

          {sections.length === 0 && !hasControls && (
            <p class="ops-empty">
              {searching ? 'No commands or controls match your search.' : 'No admin commands are available in the current configuration.'}
            </p>
          )}
        </div>
      </div>
    </section>
  );
});
