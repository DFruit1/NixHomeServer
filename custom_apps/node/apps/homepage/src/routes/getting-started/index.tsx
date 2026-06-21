import { $, component$, useContext, useSignal, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { CommandSnippet } from '../../components/CommandSnippet.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';
import { sftpKeygenCommands } from '../../shared/ui-constants.js';

const stepIds = ['sign-in', 'passwords', 'services', 'files', 'photos', 'app-setup'] as const;
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
  const showUnusedApps = useSignal(false);
  const data = homepage.data;
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const username = data?.user.username ?? '{username}';
  const serverHost = data?.sshfsHost ?? data?.serverLanHost ?? 'server';
  const visibleServices = data?.services ?? [];
  const enabledServices = visibleServices.filter((service) => service.enabled);
  const servicesToShow = showUnusedApps.value ? visibleServices : enabledServices;
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
    showUnusedApps.value = window.localStorage.getItem('homepage.showUnusedApps') === 'true';
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

  const toggleUnusedApps = $((_event: Event, target: HTMLInputElement) => {
    showUnusedApps.value = target.checked;
    window.localStorage.setItem('homepage.showUnusedApps', String(target.checked));
    document.dispatchEvent(new CustomEvent('homepage-show-unused-apps-change', { detail: { show: target.checked } }));
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

  const setupItems = [
    {
      id: 'signed-in',
      label: data?.user.username ? `Signed in as ${data.user.username}` : 'Signed in to the homepage',
      status: data?.user.username ? 'verified' : 'pending',
    },
    {
      id: 'kanidm-password',
      label: 'Confirmed Kanidm password, TOTP, and passkey work',
      status: manualChecks['kanidm-password'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'password-vault',
      label: 'Passwords service is enabled',
      status: passwordsStatus,
    },
    {
      id: 'passwords-saved',
      label: 'Saved Kanidm password, TOTP, passkey, and recovery codes',
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
      label: 'Set up browser uploads or SSHFS desktop uploads',
      status: manualChecks['file-upload'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'photos-service',
      label: 'Photos service is enabled',
      status: photosStatus,
    },
    {
      id: 'photos-mobile',
      label: 'Installed Immich mobile app and tested backup if you use photos',
      status: manualChecks['photos-mobile'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'app-first-run',
      label: 'Opened each enabled app once and finished its first-run setup',
      status: manualChecks['app-first-run'] ? 'manual' : 'pending',
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
        {item.manual ? <ManualCheck id={item.id} label={item.label} /> : <span>{item.label}</span>}
      </li>
    );
  };

  const steps = [
    {
      id: 'sign-in',
      label: 'Sign in',
      status: stepStatus(['signed-in', 'kanidm-password']),
      content: (
        <>
          <h2>Sign in and check credentials</h2>
          <p>You can already reach this homepage, so your Kanidm account exists. Before setting up apps, confirm you can still sign in directly to Kanidm and manage the credentials attached to that account.</p>
          <ul class="setup-list">{['signed-in', 'kanidm-password'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={kanidmUrl}>Kanidm</a> and sign in as {username}.
            </li>
            <li>Open the credentials or account security area in Kanidm.</li>
            <li>Confirm your password works, your TOTP code works, and at least one passkey is listed.</li>
            <li>If anything is missing, add it there before relying on the rest of the services.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl}>
              Open Kanidm
            </a>
          </div>
          <p class="getting-started-note">If Kanidm asks for a reset or credential update, complete that flow first. If you cannot get back in, ask the server admin for a new Kanidm credential reset link.</p>
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
          <p>Use Vaultwarden as the server password manager. This is where you keep the Kanidm password, TOTP seed, recovery codes, passkeys, and any app-local passwords that are not handled by Kanidm.</p>
          <ul class="setup-list">{['password-vault', 'passwords-saved'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={passwordsUrl}>Passwords</a>. If this is your first visit, create a Vaultwarden account using the email address associated with your server account.
            </li>
            <li>Create one login item named Kanidm - {username}.</li>
            <li>Save the Kanidm username, password, the {kanidmUrl} website address, and recovery codes in that item.</li>
            <li>For TOTP, edit the item and paste the TOTP secret into the authenticator key field. Vaultwarden will then generate the rotating six-digit code for you.</li>
            <li>For passkeys, install the Vaultwarden or Bitwarden browser extension or mobile app, then choose it as the passkey provider when Kanidm asks where to save a new passkey.</li>
            <li>Repeat the same pattern for app-local passwords, such as Jellyfin, Kopia, Beszel, or any other app that asks for its own login.</li>
          </ol>
          {passwordsStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={passwordsUrl}>
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
          <p>Use the Services page as the source of truth. Open every enabled card you expect to use. Some apps create your local profile the first time you open them.</p>
          <ul class="setup-list">{['services-visible', 'services-opened'].map(renderSetupItem)}</ul>
          <label class="unused-toggle">
            <input type="checkbox" checked={showUnusedApps.value} onChange$={toggleUnusedApps} />
            <span>Show inactive apps in this step</span>
          </label>
          <ul class="app-status-list">
            {servicesToShow.map((service) => (
              <li key={service.id} class={{ unavailable: !service.enabled }}>
                <StatusMark status={service.enabled ? 'verified' : 'unavailable'} />
                <span>{service.name}</span>
                <small>{service.enabled ? 'Ready to open' : 'Not enabled'}</small>
              </li>
            ))}
          </ul>
          <ol class="steps">
            <li>Open Services and click each active card you plan to use.</li>
            <li>If an app asks to approve Kanidm access, approve it.</li>
            <li>If an app shows its own first-run screen, finish that setup and save any local password in Vaultwarden.</li>
            <li>Faded cards are not active. Hover them for the admin message, then ask the server admin if you need that app enabled.</li>
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
          <p>Use Files for browser uploads. Use SSHFS when you want a desktop folder or larger repeated uploads.</p>
          <ul class="setup-list">{['files-service', 'file-upload'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={filesUrl}>Files</a> and confirm you can create a test folder.
            </li>
            <li>Open the upload guide and choose the content type you are uploading so files land in the right app folder.</li>
            <li>For desktop uploads, generate an SSH key on your computer and paste the public key into the upload guide.</li>
          </ol>
          <p class="getting-started-note">Linux or macOS SSH key command:</p>
          <CommandSnippet command={sftpKeygenCommands.linux} />
          <p class="getting-started-note">Windows PowerShell SSH key command:</p>
          <CommandSnippet command={sftpKeygenCommands.windows} />
          <p class="getting-started-note">After saving the public key, the mount target is {username}@{serverHost}:/ on port 2222. The upload guide gives copyable mount commands for Windows, macOS, and Linux.</p>
          {filesStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={filesUrl}>
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
          <p>If you use the photo library, set up Immich from both the web app and your phone before assuming camera backup is working.</p>
          <ul class="setup-list">{['photos-service', 'photos-mobile'].map(renderSetupItem)}</ul>
          <ol class="steps">
            <li>
              Open <a href={photosUrl}>Photos</a> in the browser and confirm the library loads.
            </li>
            <li>Install the Immich mobile app from your phone app store.</li>
            <li>Use {photosUrl} as the server endpoint in the mobile app.</li>
            <li>Sign in with Kanidm, choose the camera albums to back up, and leave the app open until the first backup starts.</li>
            <li>Confirm a new phone photo appears in the Photos web app.</li>
          </ol>
          {photosStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={photosUrl}>
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
      id: 'app-setup',
      label: 'Finish app setup',
      status: stepStatus(['app-first-run']),
      content: (
        <>
          <h2>Finish app-specific setup</h2>
          <p>Each service page has the exact login notes, upload notes, and first-run tips for that app. Work through the enabled services you intend to use.</p>
          <ul class="setup-list">{['app-first-run'].map(renderSetupItem)}</ul>
          <ul class="getting-started-link-list">
            {enabledServices.map((service) => (
              <li key={service.id}>
                <Link href={`/services/${encodeURIComponent(service.id)}`}>{service.name}</Link>
              </li>
            ))}
          </ul>
          <ol class="steps">
            <li>Open the detail page for each enabled service above.</li>
            <li>Read the Access and Uploads fields so you know whether it uses Kanidm, local app credentials, or a special folder.</li>
            <li>For Documents, Books, Videos, Audiobooks, Downloads, Mail Archive, or Offline Media, use the upload guide or the app detail page before moving files.</li>
            <li>For any local app password, save the username, URL, password, and recovery notes in Vaultwarden.</li>
          </ol>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/uploads">
              Open Upload Guide
            </Link>
            <Link class="secondary-link" href="/">
              Open Services
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
