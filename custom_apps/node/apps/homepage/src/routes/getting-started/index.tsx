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
      label: 'I know where to find my apps',
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
      summary: 'Learn what the server does and which apps you can use.',
      status: stepStatus(['overview-read']),
      content: (
        <>
          <span class="eyebrow">Step 1 · Overview</span>
          <h2>What this server is for</h2>
          <p class="step-lead">This is a private home server managed by your administrator. It keeps useful services in one place, including storage, media, device backup, and account tools. What you see depends on the access assigned to your account.</p>
          <div class="choice-grid" aria-label="How the server works">
            <article>
              <strong>Homepage is your starting point</strong>
              <span>Return to Services whenever you want to open an app or find its help page. Homepage only shows apps available to your account.</span>
            </article>
            <article>
              <strong>Kanidm handles most sign-ins</strong>
              <span>Your Kanidm account opens Homepage and most apps. A few apps have a separate password, and this guide points them out.</span>
            </article>
            <article>
              <strong>Apps do different jobs</strong>
              <span>Some apps store and organise your files. Others manage photos, documents, books, videos, passwords, or copies kept on your devices.</span>
            </article>
          </div>
          <h3>Apps available to you</h3>
          {enabledServices.length > 0 ? (
            <>
              <p>Your account currently has access to {enabledServices.length} app{enabledServices.length === 1 ? '' : 's'}. You do not need to use all of them.</p>
              <div class="choice-grid">
                {enabledServices.map((service) => (
                  <article key={service.id}>
                    <strong>{service.name}</strong>
                    <span>{service.description}</span>
                  </article>
                ))}
              </div>
            </>
          ) : (
            <aside class="guide-callout neutral">No apps are assigned to this account yet. You can still read the guide, but ask an admin if you expected to see an app.</aside>
          )}
          <aside class="guide-callout neutral"><strong>Where the apps run.</strong> Your phone or computer opens them, but the services themselves run on the server. Most need a connection through your home network or NetBird. Offline Media can keep selected music and videos on a device for use without a connection.</aside>
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
          <p class="step-lead">Kanidm manages the account you use for Homepage and most apps. Make sure you can sign in now and still have a way in if you lose your phone or computer.</p>
          <ul class="setup-list">{['signed-in', 'account-secured'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>Open Kanidm and check your name and primary email address. Ask an admin to fix any errors before you register for other apps.</li>
            <li>If an admin sent you a one-time account link, open it only on a trusted device. It works once and expires after one hour, so set your password and finish the sign-in-method review in the same session.</li>
            <li>Add another sign-in method, such as a passkey on a second device or an authenticator code. You should still be able to sign in if one device is lost.</li>
            <li>Sign out, then sign back in once. This confirms that your first-time setup is complete.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
          </div>
          <aside class="guide-callout">If the one-time link is expired, has already been used, or setup stops partway through, ask an admin for a new link. Never send an admin your password, authenticator code, passkey, recovery code, or the link itself.</aside>
          <aside class="guide-callout neutral"><strong>Use a trusted network path.</strong> Open private apps only while connected to your home network or NetBird. {serverLanHost ? <>If an app name does not work at home, tell the admin that you are trying to reach the server at <code>{serverLanHost}</code>.</> : 'If an app name does not work, tell the admin which network you are using.'} Never bypass a browser certificate warning.</aside>
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
          <p class="step-lead">Save your sign-in details in a password manager. Keep at least one recovery method somewhere you can reach while this server is offline.</p>
          <ul class="setup-list">{['recovery-saved'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>{passwordsStatus === 'available' ? 'Open Passwords and create a separate Vaultwarden account. Using your Kanidm email keeps the account names consistent, but it does not create SSO and the server does not verify that address.' : 'Use a password manager that you trust.'}</li>
            <li>Save your Kanidm username, sign-in page, and password together. Also note which devices hold your passkeys or authenticator app.</li>
            <li>Keep recovery codes in a second secure place that does not rely on this server.</li>
            <li>Save any password created by an individual app. It may be different from your Kanidm password.</li>
          </ol>
          <div class="choice-grid" aria-label="Account types">
            <article>
              <strong>Kanidm sign-in</strong>
              <span>Used by Homepage and most apps. Protect it with more than one sign-in method.</span>
            </article>
            {passwordsStatus === 'available' && (
              <article>
                <strong>Passwords master password</strong>
                <span>This is separate from Kanidm. The server cannot recover it for you, so save it and the vault recovery details as soon as you create the account.</span>
              </article>
            )}
            {videosStatus === 'available' && (
              <article>
                <strong>Videos password</strong>
                <span>Jellyfin uses a separate initial password. Change it on first sign-in and save the replacement.</span>
              </article>
            )}
            {backupsStatus === 'available' && (
              <article>
                <strong>Local Backups password</strong>
                <span>After the Kanidm gateway, Kopia asks for the shared native <code>kopia-admin</code> credential. Get it from an administrator through a trusted channel; do not try your Kanidm password.</span>
              </article>
            )}
            {monitorStatus === 'available' && (
              <article>
                <strong>Monitor login</strong>
                <span>After the Kanidm gateway, Beszel uses its own native account. A Kanidm reset does not reset that second login.</span>
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
                <strong>If Passwords says the email is already registered, do not create a second vault.</strong> Return to the login page and use your Vaultwarden master password, not your Kanidm password. An admin cannot reveal a lost master password. Find your personal recovery copy and ask for help before you delete or recreate anything.
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
          <p class="step-lead">The Services page lists {enabledServices.length} app{enabledServices.length === 1 ? '' : 's'} assigned to your account. Open the ones you plan to use now so you can catch access or first-time setup problems.</p>
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
              <li>Open each app you plan to use and answer any first-time setup questions.</li>
              <li>If an app creates a separate password, save it in your password manager.</li>
              <li>If an app is missing, ask an admin to check your access. If it will not open, send the admin the app name, the time it failed, the network you were using, and the exact error message.</li>
            </ol>
          ) : (
            <aside class="guide-callout neutral">No enabled apps are currently assigned to this account, so there is nothing to check here. If you expected an app, sign out and back in once, then ask an admin to verify your access.</aside>
          )}
          {videosStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Videos uses a separate Jellyfin password.</strong> Before your first login, ask an administrator for the generated initial password. Sign in with your Kanidm username, change that password immediately, and save the replacement in your password manager.
            </aside>
          )}
          {(documentsStatus === 'available' || booksStatus === 'available') && (
            <aside class="guide-callout neutral">
              <strong>Some app accounts are created on first sign-in.</strong> {documentsStatus === 'available' && 'Documents'}{documentsStatus === 'available' && booksStatus === 'available' && ' and '}{booksStatus === 'available' && 'Books'} may need a moment to create a local profile after Kanidm accepts your sign-in. Try the first sign-in once before reporting a missing account. If it still fails, do not create another local account. Ask an admin to run the app's reconciliation.
            </aside>
          )}
          {backupsStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Local Backups has two sign-in gates.</strong> Kanidm first checks the <code>backup-admin</code> role, then Kopia asks for the shared native <code>kopia-admin</code> credential. If the first gate denies access, ask an admin to check your group. If the second gate rejects the password, ask them to verify the Kopia credential instead of resetting Kanidm.
            </aside>
          )}
          {monitorStatus === 'available' && (
            <aside class="guide-callout neutral">
              <strong>Monitor also has two sign-in gates.</strong> Kanidm first checks monitoring access, then Beszel asks for its native login. A failure at the second prompt belongs to Beszel and will not be fixed by changing your Kanidm password.
            </aside>
          )}
          <aside class="guide-callout neutral">
            <strong>If access was just changed, refresh your sign-in first.</strong> Sign out of Homepage and the affected app, then sign back in to refresh your account groups. If the app is still missing or denies access, ask an admin to verify your current membership and the app's account reconciliation. Do not keep resetting your password.
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
          <p class="step-lead">{filesWebAvailable ? 'Use the Files web app for a few files.' : 'Browser file uploads are not available to your account.'} {sftpAvailable ? 'For regular or large transfers, you can also connect the server to your computer as a folder.' : 'Your account does not currently have the separate SFTP/SSHFS connection permission.'}</p>
          <ul class="setup-list">{['upload-ready'].map(renderSetupItem)}</ul>
          {fileTransferAvailable ? (
            <>
              <div class="choice-grid">
                {filesWebAvailable && <article><strong>Upload in your browser</strong><span>Use this for a few files. Open Files, choose the folder for that type of content, then drag your files into it.</span></article>}
                {sftpAvailable && <article><strong>Connect Files to your computer</strong><span>Use this for regular or large transfers. Follow the home-network-only SFTP/SSHFS guide for Windows, macOS, or Linux.</span></article>}
              </div>
              <ol class="steps">
                <li>Check the Detailed Guide before choosing a folder. Each app watches a specific location.</li>
                <li>Upload one small test file, wait for the transfer to finish, then confirm it appears in the intended app before copying a large library.</li>
                <li>Do not upload or move the same file into several watched folders to make it appear faster; that can create duplicates. If a completed file does not appear, report its destination folder and upload time.</li>
              </ol>
              <aside class="guide-callout neutral">Browser Files and SFTP/SSHFS are separate permissions. SFTP also uses a device key and is exposed only on the home network; public Homepage or NetBird access does not make the SFTP port reachable.</aside>
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
          <p class="step-lead">This step is optional. Connect only the apps that you want to use on this phone or computer.</p>
          <ul class="setup-list">{['photos-ready', 'offline-ready'].map(renderSetupItem)}</ul>
          <div class="device-setup-list">
            {photosStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Phone backup</span><h3>Photos</h3></div>
                <p>Install the Immich app. When it asks for the server address, enter the private Photos address <strong>{photosUrl}</strong>. Do not use a public photo-share link or the public share hostname. Those links only show selected albums and cannot sign the mobile app in. Choose the phone albums to back up, allow the requested photo and background permissions, and keep the app open and powered during the first upload. Take a test photo and make sure it appears before you rely on background backup.</p>
                <a class="secondary-link" href={photosUrl} target="_blank" rel="noreferrer">Open Photos</a>
              </article>
            )}
            {offlineMediaStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Offline access</span><h3>Offline Media</h3></div>
                <p>Install Syncthing-Fork on an Android phone or tablet. iPhone and iPad are not supported. Copy the device ID it shows, then open the Offline Media setup page and follow the steps. Accept offered folders as <strong>Receive Only</strong> and check that the device connects before waiting for files to download.</p>
                <Link class="secondary-link" href="/services/offline-media">Set up Offline Media</Link>
              </article>
            )}
          </div>
          {offlineMediaStatus === 'available' && (
            <aside class="guide-callout neutral">Offline Media copies from the server to your device; add new media through Files. Reinstalling Syncthing creates a new device ID, so remove the old device entry and enroll the new one. Remove lost or retired devices promptly.</aside>
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
          <p class="step-lead">You do not need to set up every app today. Check the items below, then return to this guide when you add an app or device.</p>
          <ul class="setup-list">{['overview-read', 'signed-in', 'account-secured', 'recovery-saved', 'services-opened', 'upload-ready', 'photos-ready', 'offline-ready', 'setup-reviewed'].map(renderSetupItem)}</ul>
          <div class="finish-next-steps">
            <h3>Where to go next</h3>
            <p>Use <strong>Services</strong> to open apps. {fileTransferAvailable && <><strong>Detailed Guide</strong> explains each app, which file destination to use, and how SSHFS access works. </>}Ask an admin about a missing app, account recovery, or an app that will not open.</p>
          </div>
          <aside class="guide-callout neutral">
            <strong>What to include when asking for help</strong>
            <p>Send your username, the app name, the approximate time, the network you were using (home network or NetBird), and the exact error text. A screenshot can help, but remove private document names first. Never include passwords, one-time account links, recovery codes, API tokens, or authenticator codes.</p>
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
          <p>Begin with a quick overview of what the server does. The rest of the guide helps you protect the account for {username} and set up only the apps and devices you want. The checkboxes are reminders saved in this browser, not checks performed by the server. A private window, another device, or cleared site data will have its own checklist.</p>
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
