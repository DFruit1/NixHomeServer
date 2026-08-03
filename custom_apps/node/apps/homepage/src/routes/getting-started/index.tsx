import { $, component$, useContext, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { CredentialBackupGuide } from '../../components/CredentialBackupGuide.js';
import { SftpSetup } from '../../components/SftpSetup.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';

const stepIds = ['welcome', 'account', 'recovery', 'services', 'uploads', 'devices', 'finish'] as const;
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
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const filesStatus = serviceStatus(serviceById('files'));
  const photosStatus = serviceStatus(serviceById('photos'));
  const videosStatus = serviceStatus(serviceById('videos'));
  const documentsStatus = serviceStatus(serviceById('documents'));
  const booksStatus = serviceStatus(serviceById('books'));
  const backupsStatus = serviceStatus(serviceById('backups'));
  const monitorStatus = serviceStatus(serviceById('monitor'));
  const offlineMediaStatus = serviceStatus(serviceById('offline-media'));
  const filesWebAvailable = filesStatus === 'available';
  const sftpAvailable = data?.sftp?.allowed === true;
  const fileTransferAvailable = filesWebAvailable || sftpAvailable;
  const requestedStep = location.url.searchParams.get('step');
  const activeStepId: GettingStartedStepId = isStepId(requestedStep) ? requestedStep : 'welcome';

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
    if (status === 'available') return 'Available (not checked yet)';
    if (status === 'unavailable') return 'Skip (not available for this account)';
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
      id: 'overview-read',
      label: 'I have reviewed what I may want to set up',
      status: manualChecks['overview-read'] ? 'manual' : 'pending',
      manual: true,
    },
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
      label: passwordsStatus === 'available'
        ? 'Created and tested a Passwords recovery backup'
        : 'Stored account recovery details outside this server',
      status: manualChecks['recovery-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'services-opened',
      label: 'Opened the apps I plan to use',
      status: enabledServices.length > 0 ? (manualChecks['services-opened'] ? 'manual' : 'pending') : 'unavailable',
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
      id: 'welcome',
      label: 'Start here',
      summary: 'Review the accounts, connections, and devices you may want to set up.',
      status: stepStatus(['overview-read']),
      content: (
        <>
          <span class="eyebrow">Step 1 · Overview</span>
          <h2>Choose what to set up</h2>
          <p class="step-lead">Review these options before you begin. The checklist guides you through setup; after that, explore Services or the Detailed Guide.</p>
          <div class="choice-grid" aria-label="Setup options">
            <article>
              <strong>Passwords and sign-in</strong>
              <span>Create a Vaultwarden account or use a password manager you trust. Ensure it supports passkeys or TOTP. Keep recovery details outside this server.</span>
            </article>
            <article>
              <strong>Access away from home</strong>
              <span>Install NetBird on devices for private remote access, then ask your admin to enrol them. Never bypass certificate warnings.</span>
            </article>
            <article>
              <strong>Files on a computer</strong>
              <span>SSHFS mounts server files on your computer. Install WinFsp + SSHFS-Win (Windows), macFUSE + sshfs (macOS), or sshfs (Linux).</span>
            </article>
            <article>
              <strong>Offline Media</strong>
              <span>On Android, install Syncthing-Fork from F-Droid for offline media access. Device enrolment is covered later in this guide.</span>
            </article>
            <article>
              <strong>Phone apps</strong>
              <span>Install clients from F-Droid when available: Immich, Jellyfin, Inkita, Lissen, Audiobookshelf. Use Google Play as fallback.</span>
            </article>
          </div>
          <aside class="guide-callout neutral">This checklist covers initial setup. Services shows available apps; the Detailed Guide explains features and everyday use.</aside>
          <div class="getting-started-actions compact">
            <Link class="secondary-link" href="/uploads">Browse the Detailed Guide</Link>
          </div>
          <ul class="setup-list">{['overview-read'].map(renderSetupItem)}</ul>
        </>
      ),
    },
    {
      id: 'account',
      label: 'Protect your account',
      summary: 'Check how you sign in and what happens if you lose a device.',
      status: stepStatus(['signed-in', 'account-secured']),
      content: (
        <>
          <span class="eyebrow">Step 2 · Account</span>
          <h2>Protect your account</h2>
          <p class="step-lead">Kanidm manages your account for Homepage and most apps. Verify you can sign in and have a recovery method.</p>
          <ul class="setup-list">{['signed-in', 'account-secured'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>Open Kanidm and verify your name and email. Ask an admin to fix errors before registering for other apps.</li>
            <li>If you received a one-time link, use it on a trusted device within one hour to set your password.</li>
            <li>Add a second sign-in method (passkey or authenticator) for backup access.</li>
            <li>Sign out and back in to confirm setup is complete.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
          </div>
          <aside class="guide-callout">If the one-time link expires or setup stops, ask for a new link. Never share passwords, codes, or links with admins.</aside>
          <aside class="guide-callout neutral">Use private apps only on your home network or NetBird. {serverLanHost ? <>If an app doesn't work at home, tell the admin you're reaching the server at <code>{serverLanHost}</code>.</> : "If an app doesn't work, tell the admin which network you're using."} Never bypass certificate warnings.</aside>
        </>
      ),
    },
    {
      id: 'recovery',
      label: 'Prepare for account recovery',
      summary: 'Keep recovery details somewhere safe outside the server.',
      status: stepStatus(['recovery-saved']),
      content: (
        <>
          <span class="eyebrow">Step 3 · Recovery</span>
          <h2>Prepare for account recovery</h2>
          <p class="step-lead">Save sign-in details in a password manager and keep recovery methods accessible when the server is offline.</p>
          <ul class="setup-list">{['recovery-saved'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>{passwordsStatus === 'available' ? 'Open Passwords and create a Vaultwarden account using your Kanidm email for consistency.' : 'Use a password manager you trust.'}</li>
            <li>Save your Kanidm username, sign-in page, password, and which devices hold passkeys or authenticator.</li>
            <li>Store recovery codes in a second secure location independent of this server.</li>
            <li>Save any app-specific passwords separately from your Kanidm password.</li>
          </ol>
          <div class="choice-grid" aria-label="Account types">
            <article>
              <strong>Kanidm sign-in</strong>
              <span>Used by Homepage and most apps. Add a second sign-in method.</span>
            </article>
            {passwordsStatus === 'available' && (
              <article>
                <strong>Passwords master password</strong>
                <span>Separate from Kanidm. The server cannot recover it—save it and vault recovery details immediately.</span>
              </article>
            )}
            {videosStatus === 'available' && (
              <article>
                <strong>Videos password</strong>
                <span>Jellyfin uses a separate password. Change it on first sign-in and save the new one.</span>
              </article>
            )}
            {backupsStatus === 'available' && (
              <article>
                <strong>Local Backups password</strong>
                <span>After Kanidm, Kopia asks for the <code>kopia-admin</code> credential. Get it from an admin—don't use your Kanidm password.</span>
              </article>
            )}
            {monitorStatus === 'available' && (
              <article>
                <strong>Monitor login</strong>
                <span>After Kanidm, Beszel uses its own login. A Kanidm reset doesn't affect it.</span>
              </article>
            )}
          </div>
          {passwordsStatus === 'available' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={passwordsUrl} target="_blank" rel="noreferrer">Open Passwords</a>
            </div>
          ) : (
            <aside class="guide-callout neutral">The Passwords app is not available to you. Use another password manager, or ask an admin whether you should have access.</aside>
          )}
          {passwordsStatus === 'available' && (
            <>
              <aside class="guide-callout neutral">
                <strong>If email is already registered, don't create a second vault.</strong> Use your Vaultwarden master password at login. An admin can't recover a lost master password.
              </aside>
              <CredentialBackupGuide />
            </>
          )}
        </>
      ),
    },
    {
      id: 'services',
      label: 'Open your apps',
      summary: 'Open each app you plan to use once.',
      status: stepStatus(['services-opened']),
      content: (
        <>
          <span class="eyebrow">Step 4 · Services</span>
          <h2>Open your apps</h2>
          <p class="step-lead">The Services page lists {enabledServices.length} app{enabledServices.length === 1 ? '' : 's'} assigned to your account. Open each one to catch access or setup issues early.</p>
          <ul class="setup-list">{['services-opened'].map(renderSetupItem)}</ul>
          {enabledServices.length > 0 && (
            <div class="available-service-list" aria-label="Available services">
              {enabledServices.map((service) => (
                <a key={service.id} href={service.url} target={service.url.startsWith('/') ? undefined : '_blank'} rel="noreferrer">{service.name}</a>
              ))}
            </div>
          )}
          {enabledServices.length > 0 ? (
            <ol class="steps">
              <li>Open each app you plan to use and complete any first-time setup.</li>
              <li>Save any app-specific passwords in your password manager.</li>
              <li>If an app is missing or won't open, tell the admin the app name, time, network, and error message.</li>
            </ol>
          ) : (
            <aside class="guide-callout neutral">No enabled apps are currently assigned to this account, so there is nothing to check here. If you expected an app, sign out and back in once, then ask an admin to verify your access.</aside>
          )}
          {videosStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Videos uses a separate password.</strong> Ask an admin for the initial password, change it on first sign-in, and save the new one.
            </aside>
          )}
          {(documentsStatus === 'available' || booksStatus === 'available') && (
            <aside class="guide-callout neutral">
              <strong>Some accounts are created on first sign-in.</strong> {documentsStatus === 'available' && 'Documents'}{documentsStatus === 'available' && booksStatus === 'available' && ' and '}{booksStatus === 'available' && 'Books'} may need a moment to create a local profile. Try once before reporting issues.
            </aside>
          )}
          {backupsStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Local Backups has two sign-in gates.</strong> Kanidm checks your group, then Kopia asks for a credential. If the first fails, ask an admin to check your group. If the second fails, ask them to verify the Kopia credential.
            </aside>
          )}
          {monitorStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Monitor has two sign-in gates.</strong> Kanidm checks access, then Beszel asks for its own login. A second-prompt failure won't be fixed by resetting Kanidm.
            </aside>
          )}
          <aside class="guide-callout neutral">
            <strong>If access was just changed, refresh your sign-in.</strong> Sign out and back in to refresh account groups. If the app is still missing, ask an admin to verify membership.
          </aside>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">Open Services</Link>
          </div>
        </>
      ),
    },
    {
      id: 'uploads',
      label: 'Add your files',
      summary: 'Choose the simplest way to copy files to the server.',
      status: stepStatus(['upload-ready']),
      content: (
        <>
          <span class="eyebrow">Step 5 · Files</span>
          <h2>Choose how to add files</h2>
          <p class="step-lead">{filesWebAvailable ? 'Use the Files web app for small uploads.' : 'Browser file uploads are not available.'} {sftpAvailable ? 'For regular or large transfers, connect via SSHFS.' : 'SFTP/SSHFS is not enabled for your account.'}</p>
          <ul class="setup-list">{['upload-ready'].map(renderSetupItem)}</ul>
          {fileTransferAvailable ? (
            <>
              <div class="choice-grid">
                {filesWebAvailable && <article><strong>Upload in browser</strong><span>Open Files, choose the folder, and drag files in.</span></article>}
                {sftpAvailable && <article><strong>Connect via SSHFS</strong><span>Mount the server as a folder. Follow the home-network-only guide for your OS.</span></article>}
              </div>
              <ol class="steps">
                <li>Check the Detailed Guide for folder locations—each app watches a specific path.</li>
                <li>Upload a small test file, wait for transfer, then confirm it appears in the intended app.</li>
                <li>Don't upload the same file to multiple folders—it creates duplicates. Report missing files with destination and upload time.</li>
              </ol>
              <aside class="guide-callout neutral">Browser Files and SFTP/SSHFS have separate permissions. SFTP uses a device key and is only available on the home network.</aside>
              <div class="getting-started-actions compact">
                {filesWebAvailable && <a class="primary-link" href={filesUrl} target="_blank" rel="noreferrer">Open Files</a>}
                <Link class="secondary-link" href="/uploads">Browse file placement in Detailed Guide</Link>
              </div>
              {sftpAvailable && (
                <SftpSetup
                  username={username}
                  domain={domain}
                  sftp={data!.sftp!}
                  filesWebAvailable={filesWebAvailable}
                />
              )}
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
      summary: 'Connect photo backup or offline media if you want them.',
      status: stepStatus(['photos-ready', 'offline-ready']),
      content: (
        <>
          <span class="eyebrow">Step 6 · Optional</span>
          <h2>Connect your devices</h2>
          <p class="step-lead">Connect only the apps you want to use on this device.</p>
          <ul class="setup-list">{['photos-ready', 'offline-ready'].map(renderSetupItem)}</ul>
          <div class="device-setup-list">
            {photosStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Phone backup</span><h3>Photos</h3></div>
                <p>Install Immich and enter the private address <strong>{photosUrl}</strong> (not public share links). Select albums to back up, allow photo/background permissions, and keep the app open during the first upload. Test with a photo before relying on background backup.</p>
                <a class="secondary-link" href={photosUrl} target="_blank" rel="noreferrer">Open Photos</a>
              </article>
            )}
            {offlineMediaStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Offline access</span><h3>Offline Media</h3></div>
                <p>Install Syncthing-Fork on Android (iOS not supported). Copy the device ID, open Offline Media setup, and follow the steps. Accept folders as <strong>Receive Only</strong>.</p>
                <Link class="secondary-link" href="/services/offline-media">Set up Offline Media</Link>
              </article>
            )}
          </div>
          {offlineMediaStatus === 'available' && (
            <aside class="guide-callout neutral">Offline Media copies from server to device; add new media through Files. Reinstalling Syncthing creates a new device ID—remove the old entry and enrol the new one.</aside>
          )}
          {photosStatus === 'unavailable' && offlineMediaStatus === 'unavailable' && (
            <aside class="guide-callout neutral">Photo backup and Offline Media are not available to you. You can skip this step.</aside>
          )}
        </>
      ),
    },
    {
      id: 'finish',
      label: 'Finish',
      summary: 'Review your setup and learn how to ask for help.',
      status: stepStatus(['setup-reviewed']),
      content: (
        <>
          <span class="eyebrow">Step 7 · Review</span>
          <h2>Finish setup</h2>
          <p class="step-lead">You don't need to set up everything today. Return when you add an app or device.</p>
          <ul class="setup-list">{['overview-read', 'signed-in', 'account-secured', 'recovery-saved', 'services-opened', 'upload-ready', 'photos-ready', 'offline-ready', 'setup-reviewed'].map(renderSetupItem)}</ul>
          <div class="finish-next-steps">
            <h3>Where to go next</h3>
            <p>Use <strong>Services</strong> to open apps. {fileTransferAvailable && <><strong>Detailed Guide</strong> covers app features and file destinations. </>}Ask an admin about missing apps or access issues.</p>
          </div>
          <aside class="guide-callout neutral">
            <strong>When asking for help</strong>
            <p>Include your username, app name, time, network, and exact error. Never share passwords, links, codes, or tokens.</p>
          </aside>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">Go to Services</Link>
            {fileTransferAvailable && <Link class="secondary-link" href="/uploads">Open Detailed Guide</Link>}
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
          <span class="eyebrow">First-time guide · progress is saved only in this browser profile</span>
          <h1>Get started with your home server</h1>
          <p>Review what you may want to set up, then follow the checklist to configure your account and apps. Checkboxes are saved in this browser only.</p>
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
