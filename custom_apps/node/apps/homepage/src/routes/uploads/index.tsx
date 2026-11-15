import { $, component$, useContext, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { CredentialBackupGuide } from '../../components/CredentialBackupGuide.js';
import { ServiceLogo } from '../../components/ServiceLogo.js';
import { AccessTopic } from '../../components/guide/AccessTopic.js';
import { AppTopic } from '../../components/guide/AppTopic.js';
import { FoldersTopic } from '../../components/guide/FoldersTopic.js';
import { HelpTopic } from '../../components/guide/HelpTopic.js';
import { SshfsTopic } from '../../components/guide/SshfsTopic.js';
import { categoryLabels, categoryOrder, guideHref } from '../../shared/guide-data.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';

type HowTo = { id: string; title: string; summary: string };

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const showUnused = useSignal(false);
  const data = homepage.data;
  const username = data?.user.username ?? '{username}';
  const allServices = data?.services ?? [];
  const allFolderGuides = data?.folderGuides ?? [];
  const services = allServices.filter((service) => service.enabled || showUnused.value);
  const folderGuides = allFolderGuides.filter((guide) => guide.enabled || showUnused.value);
  const filesService = allServices.find((service) => service.id === 'files' && service.enabled);
  const passwords = services.find((service) => service.id === 'passwords');
  const showSshfs = Boolean(data?.sftp && (data.sftp.allowed || (showUnused.value && data.sftp.enabled)));

  const howTos: HowTo[] = [
    { id: 'access', title: 'How sign-in works', summary: 'One account, the groups that decide what you can open, and the few apps with their own login.' },
    ...(folderGuides.length > 0
      ? [{ id: 'folders', title: 'Where files go', summary: 'The folder each app reads, the file types it accepts, and personal versus shared folders.' }]
      : []),
    ...(showSshfs
      ? [{ id: 'sshfs', title: 'Mount your files as a drive', summary: 'Set up SSHFS on Windows, macOS or Linux for large or regular transfers.' }]
      : []),
    ...(passwords
      ? [{ id: 'vault-backup', title: 'Back up your password vault', summary: 'Keep an encrypted copy of your Passwords vault that does not depend on this server.' }]
      : []),
    { id: 'help', title: 'When something does not work', summary: 'The checks that fix most problems, and what to send an admin.' },
  ];

  const serviceGroups = categoryOrder
    .map((category) => ({ category, services: services.filter((service) => service.category === category) }))
    .filter((group) => group.services.length > 0);

  // Folder topics used to be separate pages; their links now open the folder map.
  const requested = location.url.searchParams.get('guide') ?? '';
  const legacyFolder = requested.startsWith('folder-') || allFolderGuides.some((guide) => guide.id === requested);
  const requestedId = legacyFolder ? 'folders' : requested;
  const activeService = requestedId.startsWith('service-')
    ? services.find((service) => service.id === requestedId.slice('service-'.length))
    : undefined;
  const activeHowTo = howTos.find((topic) => topic.id === requestedId);
  const activeId = activeService ? `service-${activeService.id}` : activeHowTo?.id ?? '';

  useVisibleTask$(({ cleanup }) => {
    showUnused.value = window.localStorage.getItem('homepage.showUnusedAppsInDetailedGuide') === 'true';
    const onShowUnusedChange = (event: Event) => {
      const detail = (event as CustomEvent<{ show?: boolean }>).detail;
      showUnused.value = Boolean(detail?.show);
    };
    document.addEventListener('homepage-show-unused-detailed-guide-change', onShowUnusedChange);
    cleanup(() => document.removeEventListener('homepage-show-unused-detailed-guide-change', onShowUnusedChange));
  });

  const updateShowUnused = $((_event: Event, target: HTMLInputElement) => {
    showUnused.value = target.checked;
    window.localStorage.setItem('homepage.showUnusedAppsInDetailedGuide', String(target.checked));
    document.dispatchEvent(new CustomEvent('homepage-show-unused-detailed-guide-change', { detail: { show: target.checked } }));
  });

  if (!activeId) {
    return (
      <section class="doc guide">
        <header class="doc-head">
          <h1>Detailed Guide</h1>
          <p class="doc-lead">How the server works, and a page for every app you can use.</p>
        </header>

        <nav class="guide-index" aria-label="Detailed guide contents">
          <section>
            <h2>How things work</h2>
            <ul class="guide-links">
              {howTos.map((topic) => (
                <li key={topic.id}>
                  <Link href={guideHref(topic.id)}>
                    <span>
                      <strong>{topic.title}</strong>
                      <span>{topic.summary}</span>
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>

          {serviceGroups.map((group) => (
            <section key={group.category}>
              <h2>{categoryLabels[group.category]}</h2>
              <ul class="guide-links guide-links--apps">
                {group.services.map((service: ServiceCard) => (
                  <li key={service.id}>
                    <Link href={guideHref(`service-${service.id}`)} class={{ 'is-off': !service.enabled }}>
                      <ServiceLogo service={service} large />
                      <span>
                        <strong>{service.name}</strong>
                        <span>{service.description}</span>
                      </span>
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </nav>

        <label class="guide-unused">
          <input type="checkbox" checked={showUnused.value} onChange$={updateShowUnused} />
          <span>Include apps that are not enabled</span>
        </label>
      </section>
    );
  }

  return (
    <section class="doc guide">
      <div class="guide-layout">
        <nav class="guide-nav" aria-label="Detailed guide contents">
          <Link class="guide-nav__home" href="/uploads">
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path d="m15 18-6-6 6-6" /></svg>
            All topics
          </Link>
          <div class="guide-nav__lists">
            <h2>How things work</h2>
            <ul>
              {howTos.map((topic) => (
                <li key={topic.id}>
                  <Link href={guideHref(topic.id)} class={{ selected: activeId === topic.id }} aria-current={activeId === topic.id ? 'page' : undefined}>
                    {topic.title}
                  </Link>
                </li>
              ))}
            </ul>
            {serviceGroups.map((group) => (
              <div key={group.category}>
                <h2>{categoryLabels[group.category]}</h2>
                <ul>
                  {group.services.map((service: ServiceCard) => (
                    <li key={service.id}>
                      <Link
                        href={guideHref(`service-${service.id}`)}
                        class={{ selected: activeId === `service-${service.id}` }}
                        aria-current={activeId === `service-${service.id}` ? 'page' : undefined}
                      >
                        {service.name}
                      </Link>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </nav>

        {activeService && <AppTopic service={activeService} folderGuides={folderGuides} username={username} />}
        {activeId === 'access' && <AccessTopic services={services} kanidmUrl={`https://id.${data?.domain ?? 'example.test'}`} />}
        {activeId === 'folders' && (
          <FoldersTopic
            folderGuides={folderGuides}
            services={services}
            username={username}
            transferAvailable={Boolean(filesService) || data?.sftp?.allowed === true}
            sshfsAvailable={data?.sftp?.allowed === true}
          />
        )}
        {activeId === 'sshfs' && data?.sftp && <SshfsTopic sftp={data.sftp} username={username} filesUrl={filesService?.url} />}
        {activeId === 'vault-backup' && passwords && <CredentialBackupGuide passwordsUrl={passwords.url} enabled={passwords.enabled} />}
        {activeId === 'help' && <HelpTopic serverLanHost={data?.serverLanHost} />}
      </div>
    </section>
  );
});
