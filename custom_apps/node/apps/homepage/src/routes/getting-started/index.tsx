import { $, component$, useContext, useStore, useVisibleTask$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { ExplainMore } from '../../components/ExplainMore.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import { buildSetupModel, isStepId, serviceStatus } from './setup-model.js';
import { buildSteps, StatusMark } from './steps.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const manualChecks = useStore<Record<string, boolean>>({});
  const data = homepage.data;
  const domain = data?.domain ?? 'example.test';
  const username = data?.user.username ?? '{username}';
  const serverLanHost = data?.serverLanHost;
  const manualCheckStorageKey = `homepage.gettingStartedChecks.${username}`;
  const services = data?.services ?? [];
  const enabledServices = services.filter((service) => service.enabled);
  const serviceById = (id: string) => services.find((service) => service.id === id);
  const serviceUrl = (id: string, fallback: string) => serviceById(id)?.url ?? fallback;
  const kanidmUrl = `https://id.${domain}`;
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const videosUrl = serviceUrl('videos', `https://videos.${domain}`);
  const booksUrl = serviceUrl('books', `https://books.${domain}`);
  const audiobooksUrl = serviceUrl('audiobooks', `https://audiobooks.${domain}/audiobookshelf/`);
  const filesStatus = serviceStatus(serviceById('files'));
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const photosStatus = serviceStatus(serviceById('photos'));
  const videosStatus = serviceStatus(serviceById('videos'));
  const documentsStatus = serviceStatus(serviceById('documents'));
  const booksStatus = serviceStatus(serviceById('books'));
  const audiobooksStatus = serviceStatus(serviceById('audiobooks'));
  const backupsStatus = serviceStatus(serviceById('backups'));
  const monitorStatus = serviceStatus(serviceById('monitor'));
  const offlineMediaStatus = serviceStatus(serviceById('offline-media'));
  const filesWebAvailable = filesStatus === 'available';
  const sftpAvailable = data?.sftp?.allowed === true;
  const fileTransferAvailable = filesWebAvailable || sftpAvailable;
  const requestedStep = location.url.searchParams.get('step');
  const activeStepId = isStepId(requestedStep) ? requestedStep : 'welcome';

  useVisibleTask$(() => {
    const saved = window.localStorage.getItem(manualCheckStorageKey);
    if (!saved) {
      return;
    }
    try {
      const parsed = JSON.parse(saved) as unknown;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('invalid saved setup progress');
      }
      for (const [key, value] of Object.entries(parsed)) {
        if (typeof value === 'boolean') {
          manualChecks[key] = value;
        }
      }
    } catch {
      window.localStorage.removeItem(manualCheckStorageKey);
    }
  });

  const setManualCheck = $((id: string, checked: boolean) => {
    manualChecks[id] = checked;
    try {
      window.localStorage.setItem(manualCheckStorageKey, JSON.stringify(manualChecks));
    } catch {
      // Progress remains usable for this page even if browser storage is unavailable.
    }
  });

  const model = buildSetupModel({
    enabledServices,
    statuses: {
      passwords: passwordsStatus,
      files: filesStatus,
      photos: photosStatus,
      videos: videosStatus,
      documents: documentsStatus,
      books: booksStatus,
      audiobooks: audiobooksStatus,
      backups: backupsStatus,
      monitor: monitorStatus,
      offlineMedia: offlineMediaStatus,
    },
    fileTransferAvailable,
    manualChecks,
  });

  const steps = buildSteps({
    username,
    domain,
    serverLanHost,
    kanidmUrl,
    filesUrl,
    passwordsUrl,
    photosUrl,
    videosUrl,
    booksUrl,
    audiobooksUrl,
    statuses: {
      passwords: passwordsStatus,
      files: filesStatus,
      photos: photosStatus,
      videos: videosStatus,
      documents: documentsStatus,
      books: booksStatus,
      audiobooks: audiobooksStatus,
      backups: backupsStatus,
      monitor: monitorStatus,
      offlineMedia: offlineMediaStatus,
    },
    filesWebAvailable,
    sftpAvailable,
    fileTransferAvailable,
    sftp: data!.sftp!,
    enabledServices,
    setupItems: model.setupItems,
    serviceSetupIds: model.serviceSetupIds,
    optionalSetupIds: model.optionalSetupIds,
    manualChecks,
    setManualCheck,
  });

  const activeStepIndex = steps.findIndex((step) => step.id === activeStepId);
  const activeStep = steps[activeStepIndex] ?? steps[0];
  const relevantItems = model.setupItems.filter((item) => item.status !== 'unavailable' && !item.id.endsWith('-unavailable'));
  const completeItems = relevantItems.filter((item) => item.status === 'verified' || item.status === 'manual');
  const progress = relevantItems.length === 0 ? 0 : Math.round((completeItems.length / relevantItems.length) * 100);
  const previousStep = activeStepIndex > 0 ? steps[activeStepIndex - 1] : undefined;
  const nextStep = activeStepIndex < steps.length - 1 ? steps[activeStepIndex + 1] : undefined;

  return (
    <section id="guide" class="getting-started-guide">
      <aside class="getting-started-path">
        <div class="getting-started-path-header">
          <span class="eyebrow">Setup checklist</span>
          <div class="setup-progress" aria-label={`${progress}% of setup complete`}>
            <div><strong>{completeItems.length} of {relevantItems.length}</strong><span>tasks done</span></div>
            <progress max={100} value={progress}>{progress}%</progress>
          </div>
          <p>Checklist progress is saved only in this browser profile.</p>
        </div>
        <nav class="getting-started-toc" aria-label="Getting started steps">
          <ol>
            {steps.map((step) => (
              <li key={step.id}>
                <Link
                  href={`/getting-started?step=${step.id}#guide`}
                  class={{ selected: activeStepId === step.id }}
                  aria-current={activeStepId === step.id ? 'step' : undefined}
                >
                  <strong>{step.label}</strong>
                  <StatusMark status={step.status} decorative />
                </Link>
              </li>
            ))}
          </ol>
        </nav>
      </aside>

      <article class="getting-started-step">
        {activeStep.content}
        <ExplainMore title={activeStep.label} plain={activeStep.explain.plain} technical={activeStep.explain.technical} />
        <nav class="step-pagination" aria-label="Guide pagination">
          {previousStep ? <Link class="secondary-link" href={`/getting-started?step=${previousStep.id}#guide`}>&larr; {previousStep.label}</Link> : <span />}
          {nextStep && <Link class="next-step-link" href={`/getting-started?step=${nextStep.id}#guide`}>Next Step: {nextStep.label} &rarr;</Link>}
        </nav>
      </article>
    </section>
  );
});
