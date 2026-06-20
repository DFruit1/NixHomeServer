import { $, component$, useContext, useSignal, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { ServiceCard } from '../../shared/types.js';

const stepIds = ['sign-in', 'passwords', 'services', 'files'] as const;
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
  const visibleServices = data?.services ?? [];
  const enabledServices = visibleServices.filter((service) => service.enabled);
  const servicesToShow = showUnusedApps.value ? visibleServices : enabledServices;
  const serviceById = (id: string) => visibleServices.find((service) => service.id === id);
  const serviceUrl = (id: string, fallback: string) => serviceById(id)?.url ?? fallback;
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const filesStatus = serviceStatus(serviceById('files'));
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

  const toggleUnusedApps = $((_event: Event, target: HTMLInputElement) => {
    showUnusedApps.value = target.checked;
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
      label: 'Changed the temporary Kanidm password',
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
      label: 'Saved sign-in details and recovery codes',
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
      label: 'Set up file upload access if you need desktop uploads',
      status: manualChecks['file-upload'] ? 'manual' : 'pending',
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
          <h2>Sign in</h2>
          <p>Finish the Kanidm account setup first. Everything else depends on this sign-in working.</p>
          <ul class="setup-list">{['signed-in', 'kanidm-password'].map(renderSetupItem)}</ul>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">
              Open Services
            </Link>
          </div>
          <p class="getting-started-note">If the password change page did not appear, confirm with an admin that your account is no longer using a temporary password.</p>
        </>
      ),
    },
    {
      id: 'passwords',
      label: 'Save passwords',
      status: stepStatus(['password-vault', 'passwords-saved']),
      content: (
        <>
          <h2>Save passwords</h2>
          <p>Put the Kanidm password, recovery details, and any app-local passwords somewhere you can recover later.</p>
          <ul class="setup-list">{['password-vault', 'passwords-saved'].map(renderSetupItem)}</ul>
          {passwordsStatus === 'verified' ? (
            <div class="getting-started-actions compact">
              <a class="primary-link" href={passwordsUrl}>
                Open Passwords
              </a>
            </div>
          ) : (
            <p class="getting-started-note">The server password manager is not enabled for this account. Use another password manager for now.</p>
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
          <p>Use the Services page as the source of truth. App-specific setup belongs on each app page.</p>
          <ul class="setup-list">{['services-visible', 'services-opened'].map(renderSetupItem)}</ul>
          <label class="unused-toggle">
            <input type="checkbox" checked={showUnusedApps.value} onChange$={toggleUnusedApps} />
            <span>Show unused apps</span>
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
          <h2>Set up files</h2>
          <p>Browser uploads work through Files. Desktop mounts and larger uploads use the upload guide.</p>
          <ul class="setup-list">{['files-service', 'file-upload'].map(renderSetupItem)}</ul>
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
