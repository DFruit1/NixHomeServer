import { $, component$, useContext, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { CredentialBackupGuide } from '../../components/CredentialBackupGuide.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';

const stepIds = ['account', 'recovery', 'services', 'uploads', 'devices', 'finish'] as const;
type GettingStartedStepId = (typeof stepIds)[number];
type SetupStatus = 'verified' | 'available' | 'manual' | 'pending' | 'unavailable';

const isStepId = (value: string | null): value is GettingStartedStepId => stepIds.includes(value as GettingStartedStepId);
const serviceStatus = (service: ServiceCard | undefined): SetupStatus => {
  if (!service) {
    return 'unavailable';
  }
  return service.enabled ? 'available' : 'unavailable';
};

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const manualChecks = useStore<Record<string, boolean>>({});
  const data = homepage.data;
  const domain = data?.domain ?? 'example.test';
  const username = data?.user.username ?? '{username}';
  const manualCheckStorageKey = `homepage.gettingStartedChecks.${username}`;
  const services = data?.services ?? [];
  const enabledServices = services.filter((service) => service.enabled);
  const serviceById = (id: string) => services.find((service) => service.id === id);
  const serviceUrl = (id: string, fallback: string) => serviceById(id)?.url ?? fallback;
  const kanidmUrl = `https://id.${domain}`;
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const filesStatus = serviceStatus(serviceById('files'));
  const photosStatus = serviceStatus(serviceById('photos'));
  const videosStatus = serviceStatus(serviceById('videos'));
  const offlineMediaStatus = serviceStatus(serviceById('offline-media'));
  const filesWebAvailable = filesStatus === 'available';
  const sftpAvailable = data?.sftp?.allowed === true;
  const fileTransferAvailable = filesWebAvailable || sftpAvailable;
  const requestedStep = location.url.searchParams.get('step');
  const activeStepId: GettingStartedStepId = isStepId(requestedStep) ? requestedStep : 'account';

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

  const closeStepMenu = $((_event: Event, target: HTMLAnchorElement) => {
    target.closest('details')?.removeAttribute('open');
  });

  const statusLabel = (status: SetupStatus): string => {
    if (status === 'verified' || status === 'manual') return 'Done';
    if (status === 'available') return 'Available — not yet checked';
    if (status === 'unavailable') return 'Skip — this app is not available';
    return 'Not done';
  };

  const StatusMark = ({ status }: { status: SetupStatus }) => (
    <span class={{ 'setup-status': true, [status]: true }} aria-label={statusLabel(status)}>
      {status === 'verified' || status === 'manual' ? <>&#10003;</> : ''}
    </span>
  );

  const ManualCheck = ({ id, label }: { id: string; label: string }) => (
    <label class="manual-check">
      <input
        type="checkbox"
        checked={Boolean(manualChecks[id])}
        onChange$={(_event, target) => setManualCheck(id, target.checked)}
      />
      <span>{label}</span>
    </label>
  );

  const setupItems = [
    {
      id: 'signed-in',
      label: data?.user.username ? `Signed in as ${data.user.username}` : 'Signed in to the homepage',
      status: data?.user.username ? 'verified' : 'pending',
    },
    {
      id: 'account-secured',
      label: 'Checked my sign-in and account recovery options',
      status: manualChecks['account-secured'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'recovery-saved',
      label: 'Created and tested a recovery backup',
      status: manualChecks['recovery-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'services-opened',
      label: 'Opened the apps I plan to use',
      status: manualChecks['services-opened'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'upload-ready',
      label: 'Uploaded a test file or connected Files to my computer',
      status: fileTransferAvailable ? (manualChecks['upload-ready'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'photos-ready',
      label: 'Checked that a phone photo appears in Photos',
      status: photosStatus === 'available' ? (manualChecks['photos-ready'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'offline-ready',
      label: 'Connected this device to Offline Media',
      status: offlineMediaStatus === 'available' ? (manualChecks['offline-ready'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'setup-reviewed',
      label: 'Finished setting up the apps I use',
      status: manualChecks['setup-reviewed'] ? 'manual' : 'pending',
      manual: true,
    },
  ] satisfies { id: string; label: string; status: SetupStatus; manual?: boolean }[];

  const stepStatus = (ids: string[]): SetupStatus => {
    const statuses = ids.map((id) => setupItems.find((item) => item.id === id)?.status ?? 'pending');
    const relevant = statuses.filter((status) => status !== 'unavailable');
    if (relevant.length === 0) return 'unavailable';
    if (relevant.some((status) => status === 'pending')) return 'pending';
    return relevant.some((status) => status === 'manual') ? 'manual' : 'verified';
  };

  const renderSetupItem = (id: string) => {
    const item = setupItems.find((candidate) => candidate.id === id);
    if (!item) return null;
    return (
      <li key={item.id} class={{ 'setup-item': true, [item.status]: true }}>
        <StatusMark status={item.status} />
        {item.manual && item.status !== 'unavailable' ? <ManualCheck id={item.id} label={item.label} /> : <span>{item.label}</span>}
      </li>
    );
  };

  const steps = [
    {
      id: 'account',
      label: 'Protect your account',
      summary: 'Check how you sign in and recover your account.',
      status: stepStatus(['signed-in', 'account-secured']),
      content: (
        <>
          <span class="eyebrow">Step 1 · Account</span>
          <h2>Protect your account</h2>
          <p class="step-lead">Kanidm is where you manage the account used by most apps. Check that you can sign in and that you have another way in if you lose your phone or computer.</p>
          <ul class="setup-list">{['signed-in', 'account-secured'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>Open Kanidm. Check that your name and email address are correct.</li>
            <li>Check that losing one device would not remove every way you can sign in.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
          </div>
          <aside class="guide-callout">If you cannot sign in to Kanidm, stop here and ask an admin for a temporary account recovery link.</aside>
        </>
      ),
    },
    {
      id: 'recovery',
      label: 'Prepare for account recovery',
      summary: 'Keep recovery details somewhere safe outside this server.',
      status: stepStatus(['recovery-saved']),
      content: (
        <>
          <span class="eyebrow">Step 2 · Recovery</span>
          <h2>Prepare for account recovery</h2>
          <p class="step-lead">Save your sign-in details in a password manager. Keep at least one recovery method somewhere that still works when this server is offline.</p>
          <ul class="setup-list">{['recovery-saved'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>{passwordsStatus === 'available' ? 'Open the Passwords app and create its separate Vaultwarden account. Using your Kanidm email is a naming convention only; it is not SSO and the server does not verify that address.' : 'Use a password manager that you trust.'}</li>
            <li>Save your Kanidm username, sign-in page, and password. Note which devices hold your passkeys or authenticator app.</li>
            <li>Keep recovery codes in a second secure place that does not rely on this server.</li>
            <li>If an app gives you its own password, save that too. It may be different from your Kanidm password.</li>
          </ol>
          {passwordsStatus === 'available' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={passwordsUrl} target="_blank" rel="noreferrer">Open Passwords</a>
            </div>
          ) : (
            <aside class="guide-callout neutral">The Passwords app is not available to you. Use another password manager, or ask an admin whether you should have access.</aside>
          )}
          <CredentialBackupGuide />
        </>
      ),
    },
    {
      id: 'services',
      label: 'Open your apps',
      summary: 'Check that each app you need opens correctly.',
      status: stepStatus(['services-opened']),
      content: (
        <>
          <span class="eyebrow">Step 3 · Services</span>
          <h2>Open your apps</h2>
          <p class="step-lead">The Services page shows {enabledServices.length} installed app{enabledServices.length === 1 ? '' : 's'} your account is authorised to use. This list is generated from configuration; opening each app is the health check.</p>
          <ul class="setup-list">{['services-opened'].map(renderSetupItem)}</ul>
          {enabledServices.length > 0 && (
            <div class="available-service-list" aria-label="Available services">
              {enabledServices.map((service) => (
                <a key={service.id} href={service.url} target={service.url.startsWith('/') ? undefined : '_blank'} rel="noreferrer">{service.name}</a>
              ))}
            </div>
          )}
          <ol class="steps">
            <li>Open each app you plan to use. Complete any setup questions it shows.</li>
            <li>If an app creates a separate password, save it in your password manager.</li>
            <li>If an app is missing, ask an admin to check your access. If an app will not open, tell the admin its name and copy the error message.</li>
          </ol>
          {videosStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Videos uses a separate Jellyfin password.</strong> Before your first login, ask an administrator for the generated initial password. Sign in with your Kanidm username, change that password immediately, and save the replacement in your password manager.
            </aside>
          )}
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">Open Services</Link>
          </div>
        </>
      ),
    },
    {
      id: 'uploads',
      label: 'Add your files',
      summary: 'Choose how you want to copy files to the server.',
      status: stepStatus(['upload-ready']),
      content: (
        <>
          <span class="eyebrow">Step 4 · Files</span>
          <h2>Choose how to add files</h2>
          <p class="step-lead">{filesWebAvailable ? 'Use the Files web app for a few files.' : 'Browser file uploads are not available to your account.'} {sftpAvailable ? 'For regular or large transfers, you can also connect the server to your computer as a folder.' : 'Your account does not currently have the separate SFTP/SSHFS connection permission.'}</p>
          <ul class="setup-list">{['upload-ready'].map(renderSetupItem)}</ul>
          {fileTransferAvailable ? (
            <>
              <div class="choice-grid">
                {filesWebAvailable && <article><strong>Upload in your browser</strong><span>Best for a few files. Open Files, choose the folder for that type of content, then drag your files into it.</span></article>}
                {sftpAvailable && <article><strong>Connect Files to your computer</strong><span>Best for regular or large transfers. Follow the LAN-only guide for Windows, macOS, or Linux.</span></article>}
              </div>
              <aside class="guide-callout neutral">Check the upload guide before choosing a folder. Each app imports files from a specific folder. Using the wrong one can stop the file from appearing or create a duplicate later.</aside>
              <div class="getting-started-actions compact">
                {filesWebAvailable && <a class="primary-link" href={filesUrl} target="_blank" rel="noreferrer">Open Files</a>}
                <Link class="secondary-link" href="/uploads">See where and how to upload</Link>
              </div>
            </>
          ) : (
            <aside class="guide-callout neutral">Neither browser file uploads nor SFTP/SSHFS are available to you. Skip this step, or ask an admin if you need file-transfer access.</aside>
          )}
        </>
      ),
    },
    {
      id: 'devices',
      label: 'Connect devices',
      summary: 'Optional: connect photo backup or offline media.',
      status: stepStatus(['photos-ready', 'offline-ready']),
      content: (
        <>
          <span class="eyebrow">Step 5 · Optional</span>
          <h2>Connect your devices</h2>
          <p class="step-lead">This step is optional. Connect only the apps that you want to use on this phone or computer.</p>
          <ul class="setup-list">{['photos-ready', 'offline-ready'].map(renderSetupItem)}</ul>
          <div class="device-setup-list">
            {photosStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Phone backup</span><h3>Photos</h3></div>
                <p>Install the Immich app and enter <strong>{photosUrl}</strong> when it asks for the server address. Sign in, choose the phone albums to back up, and keep the app open for the first upload. Then check that a new photo appears in Photos.</p>
                <a class="secondary-link" href={photosUrl} target="_blank" rel="noreferrer">Open Photos</a>
              </article>
            )}
            {offlineMediaStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Offline access</span><h3>Offline Media</h3></div>
                <p>Install Syncthing, the app used to copy media to this device. Copy the device ID it shows, then open the Offline Media setup page and follow the steps. Check that your device appears before waiting for files to download.</p>
                <Link class="secondary-link" href="/services/offline-media">Set up Offline Media</Link>
              </article>
            )}
          </div>
          {photosStatus === 'unavailable' && offlineMediaStatus === 'unavailable' && (
            <aside class="guide-callout neutral">Photo backup and Offline Media are not available to you. You can skip this step.</aside>
          )}
        </>
      ),
    },
    {
      id: 'finish',
      label: 'Finish',
      summary: 'Check your setup and find help when you need it.',
      status: stepStatus(['setup-reviewed']),
      content: (
        <>
          <span class="eyebrow">Step 6 · Review</span>
          <h2>Finish setup</h2>
          <p class="step-lead">You do not need to set up every app today. Check the items below, then return to this guide when you add an app or device.</p>
          <ul class="setup-list">{['signed-in', 'account-secured', 'recovery-saved', 'services-opened', 'upload-ready', 'photos-ready', 'offline-ready', 'setup-reviewed'].map(renderSetupItem)}</ul>
          <div class="finish-next-steps">
            <h3>Where to go next</h3>
            <p><strong>Services</strong> opens your apps and their help pages. <strong>How to Upload Files</strong> shows which folder to use and how to connect Files to your computer. Ask an admin about a missing app, account recovery, or an app that will not open.</p>
          </div>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">Go to Services</Link>
            <Link class="secondary-link" href="/uploads">Open Upload Guide</Link>
          </div>
        </>
      ),
    },
  ] satisfies { id: GettingStartedStepId; label: string; summary: string; status: SetupStatus; content: JSXOutput }[];

  const activeStepIndex = steps.findIndex((step) => step.id === activeStepId);
  const activeStep = steps[activeStepIndex] ?? steps[0];
  const relevantItems = setupItems.filter((item) => item.status !== 'unavailable');
  const completeItems = relevantItems.filter((item) => item.status === 'verified' || item.status === 'manual');
  const progress = relevantItems.length === 0 ? 0 : Math.round((completeItems.length / relevantItems.length) * 100);
  const previousStep = activeStepIndex > 0 ? steps[activeStepIndex - 1] : undefined;
  const nextStep = activeStepIndex < steps.length - 1 ? steps[activeStepIndex + 1] : undefined;

  return (
    <section id="guide" class="getting-started-guide">
      <header class="getting-started-header">
        <div>
          <span class="eyebrow">First-time setup · your progress is saved on this device</span>
          <h1>Set up your account</h1>
          <p>Start by protecting the account for {username}. Then set up only the apps and devices you plan to use.</p>
        </div>
        <div class="setup-progress" aria-label={`${progress}% of setup complete`}>
          <div><strong>{completeItems.length} of {relevantItems.length}</strong><span>tasks done</span></div>
          <progress max={100} value={progress}>{progress}%</progress>
        </div>
      </header>

      <aside class="getting-started-path">
        <details>
          <summary>
            <span class="eyebrow">Setup steps</span>
            <strong>Step {activeStepIndex + 1} of {steps.length} · {activeStep.label}</strong>
            <small>Show all steps</small>
          </summary>
          <nav class="getting-started-toc" aria-label="Getting started steps">
            <ol>
              {steps.map((step, index) => (
                <li key={step.id}>
                  <Link
                    href={`/getting-started?step=${step.id}#guide`}
                    class={{ selected: activeStepId === step.id }}
                    onClick$={closeStepMenu}
                  >
                    <span class="step-number" aria-hidden="true">{index + 1}</span>
                    <span class="step-label"><strong>{step.label}</strong><small>{step.summary}</small></span>
                    <StatusMark status={step.status} />
                  </Link>
                </li>
              ))}
            </ol>
          </nav>
        </details>
      </aside>

      <article class="getting-started-step">
        {activeStep.content}
        <nav class="step-pagination" aria-label="Guide pagination">
          {previousStep ? <Link class="secondary-link" href={`/getting-started?step=${previousStep.id}#guide`}>&larr; {previousStep.label}</Link> : <span />}
          {nextStep && <Link class="primary-link" href={`/getting-started?step=${nextStep.id}#guide`}>{nextStep.label} &rarr;</Link>}
        </nav>
      </article>
    </section>
  );
});
