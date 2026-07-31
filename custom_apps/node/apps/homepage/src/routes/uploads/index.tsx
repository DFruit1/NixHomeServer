import { component$, useContext, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { DetailedGuideOverview } from '../../components/DetailedGuideOverview.js';
import { DetailedServiceGuide } from '../../components/DetailedServiceGuide.js';
import { GuidePanel } from '../../components/GuidePanel.js';
import { SshfsGuide } from '../../components/SshfsGuide.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard, ServiceCategory } from '../../shared/types.js';

const categoryOrder: ServiceCategory[] = ['files', 'media', 'knowledge', 'identity', 'operations'];
const categoryLabels: Record<ServiceCategory, string> = {
  files: 'Files and documents',
  media: 'Media',
  knowledge: 'Knowledge',
  identity: 'Accounts and identity',
  operations: 'Operations',
};

const guideHref = (guide: string) => `/uploads?guide=${encodeURIComponent(guide)}#guide-detail`;

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const showUnused = useSignal(false);
  const data = homepage.data;
  const allServices = data?.services ?? [];
  const allFolderGuides = data?.folderGuides ?? [];
  const services = allServices.filter((service) => service.enabled || showUnused.value);
  const folderGuides = allFolderGuides.filter((guide) => guide.enabled || showUnused.value);
  const filesWebAvailable = allServices.some((service) => service.id === 'files' && service.enabled);
  const showSshfs = Boolean(data?.sftp && (data.sftp.allowed || (showUnused.value && data.sftp.enabled)));
  const requestedGuide = location.url.searchParams.get('guide') ?? 'overview';
  const legacyFolderGuide = allFolderGuides.find((guide) => guide.id === requestedGuide);
  const normalizedGuide = legacyFolderGuide ? `folder-${legacyFolderGuide.id}` : requestedGuide;
  const requestedService = normalizedGuide.startsWith('service-')
    ? services.find((service) => service.id === normalizedGuide.slice('service-'.length))
    : undefined;
  const requestedFolder = normalizedGuide.startsWith('folder-')
    ? folderGuides.find((guide) => guide.id === normalizedGuide.slice('folder-'.length))
    : undefined;
  const activeGuide = requestedService
    ? `service-${requestedService.id}`
    : requestedFolder
      ? `folder-${requestedFolder.id}`
      : normalizedGuide === 'sshfs' && showSshfs
        ? 'sshfs'
        : 'overview';
  const enabledServiceCount = allServices.filter((service) => service.enabled).length;
  const serviceGroups = categoryOrder
    .map((category) => ({
      category,
      services: services.filter((service) => service.category === category),
    }))
    .filter((group) => group.services.length > 0);

  useVisibleTask$(({ cleanup }) => {
    showUnused.value = window.localStorage.getItem('homepage.showUnusedAppsInDetailedGuide') === 'true';
    const onShowUnusedChange = (event: Event) => {
      const detail = (event as CustomEvent<{ show?: boolean }>).detail;
      showUnused.value = Boolean(detail?.show);
    };
    document.addEventListener('homepage-show-unused-detailed-guide-change', onShowUnusedChange);
    cleanup(() => document.removeEventListener('homepage-show-unused-detailed-guide-change', onShowUnusedChange));
  });

  return (
    <section class="section detailed-guide-page">
      <header class="section-heading stacked detailed-guide-heading">
        <span class="eyebrow">Apps, features, files, and troubleshooting</span>
        <h1>Detailed Guide</h1>
        <p>Choose a topic from the contents. Disabled apps and file workflows stay hidden unless you turn on “Show unused apps in Detailed Guide” in your profile.</p>
      </header>

      <div class="detailed-guide-layout">
        <nav class="detailed-guide-toc" aria-label="Detailed guide contents">
          <h2>Contents</h2>
          <section>
            <h3>Start here</h3>
            <ul>
              <li><Link class={{ selected: activeGuide === 'overview' }} href="/uploads#guide-detail">Overview</Link></li>
              {showSshfs && <li><Link class={{ selected: activeGuide === 'sshfs' }} href={guideHref('sshfs')}>SSHFS Mount</Link></li>}
            </ul>
          </section>

          {serviceGroups.map((group) => (
            <section key={group.category}>
              <h3>{categoryLabels[group.category]}</h3>
              <ul>
                {group.services.map((service: ServiceCard) => (
                  <li key={service.id}>
                    <Link
                      class={{ selected: activeGuide === `service-${service.id}` }}
                      href={guideHref(`service-${service.id}`)}
                    >
                      {service.name}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          ))}

          {folderGuides.length > 0 && (
            <section>
              <h3>File placement</h3>
              <ul>
                {folderGuides.map((guide) => (
                  <li key={guide.id}>
                    <Link
                      class={{ selected: activeGuide === `folder-${guide.id}` }}
                      href={guideHref(`folder-${guide.id}`)}
                    >
                      {guide.title}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </nav>

        <div class="detailed-guide-content">
          {activeGuide === 'overview' && <DetailedGuideOverview enabledServiceCount={enabledServiceCount} />}
          {requestedService && activeGuide === `service-${requestedService.id}` && (
            <DetailedServiceGuide service={requestedService} folderGuides={allFolderGuides} />
          )}
          {requestedFolder && activeGuide === `folder-${requestedFolder.id}` && (
            <GuidePanel guide={requestedFolder} username={data?.user.username ?? '{username}'} />
          )}
          {activeGuide === 'sshfs' && data?.sftp && (
            <SshfsGuide sftp={data.sftp} filesWebAvailable={filesWebAvailable} />
          )}
        </div>
      </div>
    </section>
  );
});
