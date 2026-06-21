import { $, component$, useContext, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { CommandSnippet } from '../../components/CommandSnippet.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';
import { sftpKeygenCommands } from '../../shared/ui-constants.js';

const stepIds = ['sign-in', 'secure-account', 'passwords', 'services', 'files', 'photos', 'finish'] as const;
type GettingStartedStepId = (typeof stepIds)[number];
type SetupStatus = 'verified' | 'manual' | 'pending' | 'unavailable';

const isStepId = (value: string | null): value is GettingStartedStepId => stepIds.includes(value as GettingStartedStepId);

const manualCheckStorageKey = 'homepage.gettingStartedChecks';

const serviceStatus = (service: ServiceCard | undefined): SetupStatus => {
  if (!service) {
    return 'unavailable';
  }
  return service.enabled ? 'verified' : 'unavailable';
};

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const manualChecks = useStore<Record<string, boolean>>({});
  const data = homepage.data;
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const username = data?.user.username ?? '{username}';
  const serverHost = data?.sshfsHost ?? data?.serverLanHost ?? 'server';
  const visibleServices = data?.services ?? [];
  const enabledServices = visibleServices.filter((service) => service.enabled);
  const serviceById = (id: string) => visibleServices.find((service) => service.id === id);
  const serviceUrl = (id: string, fallback: string) => serviceById(id)?.url ?? fallback;
  const kanidmUrl = `https://id.${domain}`;
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const filesStatus = serviceStatus(serviceById('files'));
  const photosStatus = serviceStatus(serviceById('photos'));
  const requestedStep = location.url.searchParams.get('step');
  const activeStepId: GettingStartedStepId = isStepId(requestedStep) ? requestedStep : 'sign-in';

  useVisibleTask$(() => {
    const saved = window.localStorage.getItem(manualCheckStorageKey);
    if (!saved) {
      return;
    }
    try {
      Object.assign(manualChecks, JSON.parse(saved) as Record<string, boolean>);
    } catch {
      window.localStorage.removeItem(manualCheckStorageKey);
    }
  });

  const setManualCheck = $((id: string, checked: boolean) => {
    manualChecks[id] = checked;
    window.localStorage.setItem(manualCheckStorageKey, JSON.stringify(manualChecks));
  });

  const statusLabel = (status: SetupStatus): string => {
    if (status === 'verified') {
      return 'Verified';
    }
    if (status === 'manual') {
      return 'Confirmed';
    }
    if (status === 'unavailable') {
      return 'Not enabled';
    }
    return 'Needs confirmation';
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
        onChange$={(event, target) => {
          void event;
          void setManualCheck(id, target.checked);
        }}
      />
      <span>{label}</span>
    </label>
  );

  const OptionalStatusText = ({ status, enabledText }: { status: SetupStatus; enabledText: string }) => (
    <p class="getting-started-note">
      {status === 'verified' ? enabledText : 'This service is not enabled for this account. Skip this step unless an admin grants access later.'}
    </p>
  );

  const setupItems = [
    {
      id: 'signed-in',
      label: data?.user.username ? `Signed in as ${data.user.username}` : 'Signed in to the homepage',
      status: data?.user.username ? 'verified' : 'pending',
    },
    {
      id: 'kanidm-direct-signin',
      label: 'Confirmed direct Kanidm sign-in works',
      status: manualChecks['kanidm-direct-signin'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'kanidm-security',
      label: 'Confirmed password, TOTP, passkey, and recovery options',
      status: manualChecks['kanidm-security'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'password-vault',
      label: 'Passwords service is enabled',
      status: passwordsStatus,
    },
    {
      id: 'passwords-saved',
      label: 'Saved account credentials, TOTP, passkey, and recovery details',
      status: manualChecks['passwords-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'services-visible',
      label: enabledServices.length > 0 ? `${enabledServices.length} service${enabledServices.length === 1 ? '' : 's'} available to this account` : 'Services available to this account',
      status: enabledServices.length > 0 ? 'verified' : 'pending',
    },
    {
      id: 'services-opened',
      label: 'Opened the services you expect to use',
      status: manualChecks['services-opened'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'files-service',
      label: 'Files service is enabled',
      status: filesStatus,
    },
    {
      id: 'file-upload',
      label: 'Chose browser uploads or SSHFS desktop uploads',
      status: filesStatus === 'verified' ? (manualChecks['file-upload'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'photos-service',
      label: 'Photos service is enabled',
      status: photosStatus,
    },
    {
      id: 'photos-mobile',
      label: 'Installed Immich mobile app and tested backup',
      status: photosStatus === 'verified' ? (manualChecks['photos-mobile'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'setup-reviewed',
      label: 'Reviewed app-specific setup notes for the services you use',
      status: manualChecks['setup-reviewed'] ? 'manual' : 'pending',
      manual: true,
    },
  ] satisfies {
    id: string;
    label: string;
    status: SetupStatus;
    manual?: boolean;
  }[];

  const stepStatus = (ids: string[]): SetupStatus => {
    const statuses = ids.map((id) => setupItems.find((item) => item.id === id)?.status ?? 'pending');
    if (statuses.some((status) => status === 'pending')) {
      return 'pending';
    }
    if (statuses.every((status) => status === 'unavailable')) {
      return 'unavailable';
    }
    return statuses.some((status) => status === 'manual') ? 'manual' : 'verified';
  };

  const renderSetupItem = (id: string) => {
    const item = setupItems.find((candidate) => candidate.id === id);
    if (!item) {
      return null;
    }
    return (
      <li key={item.id} class={{ 'setup-item': true, [item.status]: true }}>
        <StatusMark status={item.status} />
        {item.manual && item.status !== 'unavailable' ? <ManualCheck id={item.id} label={item.label} /> : <span>{item.label}</span>}
      </li>
    );
  };

  const steps = [
    {
      id: 'sign-in',
      label: 'Sign in',
      status: stepStatus(['signed-in']),
      content: (
        <>
          <h2>Sign in</h2>
          <p>Start by confirming you can reach the identity system directly. Keep this guide open while Kanidm opens in a separate tab.</p>
          <ul class="setup-list">{['signed-in'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>Open Kanidm and sign in as {username}.</li>
            <li>Return to this guide after the Kanidm page loads successfully.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">
              Open Kanidm
            </a>
          </div>
          <p class="getting-started-note">If Kanidm asks for a reset or credential update, complete that flow before setting up the apps.</p>
        </>
      ),
    },
    {
      id: 'secure-account',
      label: 'Secure account',
      status: stepStatus(['kanidm-direct-signin', 'kanidm-security']),
      content: (
        <>
          <h2>Secure your account</h2>
          <p>Confirm the credentials attached to your Kanidm account before relying on the rest of the server. This avoids getting halfway through app setup with a weak or incomplete login.</p>
          <ul class="setup-list">{['kanidm-direct-signin', 'kanidm-security'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={kanidmUrl} target="_blank" rel="noreferrer">Kanidm</a> and sign in directly as {username}.
            </li>
            <li>Open the credentials or account security area.</li>
            <li>Confirm your password works, your TOTP code works, at least one passkey is listed, and recovery options are available.</li>
            <li>If anything is missing, add it now before moving on.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">
              Open Kanidm
            </a>
          </div>
          <p class="getting-started-note">If you cannot get back in, ask the server admin for a new Kanidm credential reset link.</p>
        </>
      ),
    },
    {
      id: 'passwords',
      label: 'Save passwords',
      status: stepStatus(['password-vault', 'passwords-saved']),
      content: (
        <>
          <h2>Save passwords and recovery details</h2>
          <p>Save the account details you just verified before opening more apps. Vaultwarden is the preferred server password manager when it is enabled for your account.</p>
          <ul class="setup-list">{['password-vault', 'passwords-saved'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={passwordsUrl} target="_blank" rel="noreferrer">Passwords</a>. If this is your first visit, create a Vaultwarden account using the email address associated with your server account.
            </li>
            <li>Create one login item named Kanidm - {username}.</li>
            <li>Save the Kanidm username, password, {kanidmUrl}, TOTP seed, passkey notes, and recovery codes in that item.</li>
            <li>Install the Vaultwarden or Bitwarden browser extension or mobile app if you want it to store passkeys.</li>
            <li>Repeat this pattern later for any app that asks for its own local password.</li>
          </ol>
          {passwordsStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={passwordsUrl} target="_blank" rel="noreferrer">
                Open Passwords
              </a>
            </div>
          ) : (
            <p class="getting-started-note">The server password manager is not enabled for this account. Use another password manager now and ask an admin to enable Passwords if you should have it.</p>
          )}
        </>
      ),
    },
    {
      id: 'services',
      label: 'Open services',
      status: stepStatus(['services-visible', 'services-opened']),
      content: (
        <>
          <h2>Open services</h2>
          <p>Use the Services page as the source of truth. Open the apps you expect to use from there, and let each app finish any first-run login or profile setup.</p>
          <ul class="setup-list">{['services-visible', 'services-opened'].map(renderSetupItem)}</ul>
          <p class="getting-started-note">
            {enabledServices.length > 0
              ? `${enabledServices.length} service${enabledServices.length === 1 ? '' : 's'} available to this account.`
              : 'No services are currently available to this account.'}
          </p>
          <ol class="steps">
            <li>Open Services and click each active card you plan to use.</li>
            <li>If an app asks to approve Kanidm access, approve it.</li>
            <li>If an app shows its own first-run screen, finish that setup and save any local password in your password manager.</li>
            <li>Use each service detail page only when you need app-specific upload, login, or first-run notes.</li>
          </ol>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">
              Open Services
            </Link>
          </div>
        </>
      ),
    },
    {
      id: 'files',
      label: 'Set up files',
      status: stepStatus(['files-service', 'file-upload']),
      content: (
        <>
          <h2>Set up files and uploads</h2>
          <p>Use Files for browser uploads. Use SSHFS only if you want a desktop folder or larger repeated uploads.</p>
          <ul class="setup-list">{['files-service', 'file-upload'].map(renderSetupItem)}</ul>
          <OptionalStatusText status={filesStatus} enabledText="Files is enabled for this account." />
          <ol class="steps">
            <li>
              Open <a href={filesUrl} target="_blank" rel="noreferrer">Files</a> and confirm you can create a test folder.
            </li>
            <li>Open the upload guide and choose the content type you are uploading so files land in the right app folder.</li>
            <li>Optional: for desktop uploads, generate an SSH key on your computer and paste the public key into the upload guide.</li>
          </ol>
          <p class="getting-started-note">Linux or macOS SSH key command:</p>
          <CommandSnippet command={sftpKeygenCommands.linux} />
          <p class="getting-started-note">Windows PowerShell SSH key command:</p>
          <CommandSnippet command={sftpKeygenCommands.windows} />
          <p class="getting-started-note">After saving the public key, the mount target is {username}@{serverHost}:/ on port 2222. The upload guide gives copyable mount commands for Windows, macOS, and Linux.</p>
          {filesStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={filesUrl} target="_blank" rel="noreferrer">
                Open Files
              </a>
              <Link class="secondary-link" href="/uploads">
                Upload guide
              </Link>
            </div>
          ) : (
            <p class="getting-started-note">Files is not enabled for this account. Skip this unless an admin grants file access.</p>
          )}
        </>
      ),
    },
    {
      id: 'photos',
      label: 'Set up photos',
      status: stepStatus(['photos-service', 'photos-mobile']),
      content: (
        <>
          <h2>Set up photos and phone backup</h2>
          <p>This step is optional. If you use the photo library, set up Immich from both the web app and your phone before assuming camera backup is working.</p>
          <ul class="setup-list">{['photos-service', 'photos-mobile'].map(renderSetupItem)}</ul>
          <OptionalStatusText status={photosStatus} enabledText="Photos is enabled for this account." />
          <ol class="steps">
            <li>
              Open <a href={photosUrl} target="_blank" rel="noreferrer">Photos</a> in the browser and confirm the library loads.
            </li>
            <li>Install the Immich mobile app from your phone app store.</li>
            <li>Use {photosUrl} as the server endpoint in the mobile app.</li>
            <li>Sign in with Kanidm, choose the camera albums to back up, and leave the app open until the first backup starts.</li>
            <li>Confirm a new phone photo appears in the Photos web app.</li>
          </ol>
          {photosStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={photosUrl} target="_blank" rel="noreferrer">
                Open Photos
              </a>
              <Link class="secondary-link" href="/services/photos">
                Photos setup notes
              </Link>
            </div>
          ) : (
            <p class="getting-started-note">Photos is not enabled for this account. Skip this unless an admin enables Immich for you.</p>
          )}
        </>
      ),
    },
    {
      id: 'finish',
      label: 'Review setup',
      status: stepStatus(['setup-reviewed']),
      content: (
        <>
          <h2>Review setup</h2>
          <p>Use this final pass to confirm the account is usable without turning the guide into another service directory.</p>
          <ul class="setup-list">{['signed-in', 'kanidm-security', 'passwords-saved', 'services-opened', 'file-upload', 'photos-mobile', 'setup-reviewed'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>Use Services for app-specific detail pages when you need login, upload, or first-run notes.</li>
            <li>Use the upload guide before moving files into Documents, Books, Videos, Audiobooks, Downloads, Mail Archive, or Offline Media folders.</li>
            <li>Save any local app password in your password manager before closing that app.</li>
          </ol>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">
              Open Services
            </Link>
            <Link class="secondary-link" href="/uploads">
              Open Upload Guide
            </Link>
          </div>
        </>
      ),
    },
  ] satisfies {
    id: GettingStartedStepId;
    label: string;
    status: SetupStatus;
    content: JSXOutput;
  }[];
  const activeStep = steps.find((step) => step.id === activeStepId) ?? steps[0];

  return (
    <section id="guide" class="getting-started-guide">
      <nav class="getting-started-toc" aria-label="Getting started steps">
        <ol>
          {steps.map((step) => (
            <li key={step.id}>
              <Link href={`/getting-started?step=${step.id}#guide`} class={{ selected: activeStepId === step.id }}>
                <StatusMark status={step.status} />
                <span>{step.label}</span>
              </Link>
            </li>
          ))}
        </ol>
      </nav>

      <article class="getting-started-step">{activeStep.content}</article>
    </section>
  );
});

export const head: DocumentHead = {
  title: 'Getting Started | Sydney Basin Services',
};
