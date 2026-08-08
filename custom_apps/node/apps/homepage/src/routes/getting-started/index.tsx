import { $, component$, useContext, useStore, useVisibleTask$, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { CredentialBackupGuide } from '../../components/CredentialBackupGuide.js';
import { ExplainMore } from '../../components/ExplainMore.js';
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

const serviceSetupLabel = (service: ServiceCard): string => {
  switch (service.id) {
    case 'passwords':
      return 'Open Passwords and register with your email, or sign in with your existing master password';
    case 'backups':
      return 'Open Local Backups and sign in with the Kopia password from an admin';
    case 'monitor':
      return 'Open Monitor and sign in with the Beszel login from an admin';
    default:
      return `Open ${service.name} once to finish setup with your Kanidm sign-in`;
  }
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
  const videosUrl = serviceUrl('videos', `https://videos.${domain}`);
  const booksUrl = serviceUrl('books', `https://books.${domain}`);
  const audiobooksUrl = serviceUrl('audiobooks', `https://audiobooks.${domain}/audiobookshelf/`);
  const passwordsStatus = serviceStatus(serviceById('passwords'));
  const filesStatus = serviceStatus(serviceById('files'));
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

  const statusLabel = (status: SetupStatus): string => {
    if (status === 'verified' || status === 'manual') return 'Done';
    if (status === 'available') return 'Available (not checked yet)';
    if (status === 'unavailable') return 'Skip (not available for this account)';
    return 'Not done';
  };

  const StatusMark = ({ status, decorative = false }: { status: SetupStatus; decorative?: boolean }) => (
    <span class={{ 'setup-status': true, [status]: true }} aria-label={decorative ? undefined : statusLabel(status)} aria-hidden={decorative ? 'true' : undefined}>
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

  const serviceSetupItems = enabledServices.map((service) => ({
    id: `service-opened-${service.id}`,
    label: serviceSetupLabel(service),
    status: manualChecks[`service-opened-${service.id}`] ? 'manual' as const : 'pending' as const,
    manual: true,
  }));
  const serviceSetupIds = serviceSetupItems.map((item) => item.id);
  const optionalSetupItems = [
    ...(photosStatus === 'available' ? [
      { id: 'photos-app-installed', label: 'Install Immich on your phone', status: manualChecks['photos-app-installed'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'photos-connected', label: 'Connect Immich to the private Photos address', status: manualChecks['photos-connected'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'photos-ready', label: 'Take a test photo and confirm it appears in Photos', status: manualChecks['photos-ready'] ? 'manual' as const : 'pending' as const, manual: true },
    ] : []),
    ...(videosStatus === 'available' ? [
      { id: 'jellyfin-installed', label: 'Install Jellyfin on the phone, TV, or computer you will use', status: manualChecks['jellyfin-installed'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'jellyfin-connected', label: 'Connect Jellyfin and play a test video', status: manualChecks['jellyfin-connected'] ? 'manual' as const : 'pending' as const, manual: true },
    ] : []),
    ...(booksStatus === 'available' ? [
      { id: 'inkita-installed', label: 'Install Inkita on Android if you want a native Books client', status: manualChecks['inkita-installed'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'inkita-connected', label: 'Connect Inkita to Books and open a test book', status: manualChecks['inkita-connected'] ? 'manual' as const : 'pending' as const, manual: true },
    ] : []),
    ...(audiobooksStatus === 'available' ? [
      { id: 'audiobooks-app-installed', label: 'Install Lissen or Audiobookshelf on Android', status: manualChecks['audiobooks-app-installed'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'audiobooks-connected', label: 'Connect the audiobook app and play a test chapter', status: manualChecks['audiobooks-connected'] ? 'manual' as const : 'pending' as const, manual: true },
    ] : []),
    ...(offlineMediaStatus === 'available' ? [
      { id: 'syncthing-installed', label: 'Install Syncthing-Fork on your Android device', status: manualChecks['syncthing-installed'] ? 'manual' as const : 'pending' as const, manual: true },
      { id: 'offline-ready', label: 'Enrol the device and confirm an Offline Media folder syncs', status: manualChecks['offline-ready'] ? 'manual' as const : 'pending' as const, manual: true },
    ] : []),
  ];
  const optionalSetupIds = optionalSetupItems.map((item) => item.id);
  const setupItems = [
    {
      id: 'manager-installed',
      label: 'Install a password manager on a trusted device',
      status: manualChecks['manager-installed'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'manager-vault-created',
      label: 'Create or open a password vault and protect it with a strong master password',
      status: manualChecks['manager-vault-created'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'account-profile-confirmed',
      label: 'Confirm your name and email in Kanidm',
      status: manualChecks['account-profile-confirmed'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'account-password-set',
      label: 'Use your one-time link to set a Kanidm password if your admin sent one',
      status: manualChecks['account-password-set'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'account-second-factor',
      label: 'Add a passkey or authenticator as a second sign-in method',
      status: manualChecks['account-second-factor'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'account-login-tested',
      label: 'Sign out and sign back in to test your account',
      status: manualChecks['account-login-tested'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'recovery-login-saved',
      label: 'Save your Kanidm username and sign-in address in your password manager',
      status: manualChecks['recovery-login-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'recovery-methods-saved',
      label: 'Record which devices hold your passkeys or authenticator',
      status: manualChecks['recovery-methods-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'recovery-backup-saved',
      label: passwordsStatus === 'available' ? 'Create and test a Passwords recovery backup' : 'Back up your password vault outside this server',
      status: manualChecks['recovery-backup-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    ...serviceSetupItems,
    {
      id: 'services-unavailable',
      label: 'No services are assigned to this account',
      status: enabledServices.length === 0 ? 'unavailable' : 'verified',
    },
    {
      id: 'file-destinations-reviewed',
      label: 'Check the Detailed Guide for the correct destination folder',
      status: fileTransferAvailable ? (manualChecks['file-destinations-reviewed'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'file-transferred',
      label: 'Transfer one small test file to the server',
      status: fileTransferAvailable ? (manualChecks['file-transferred'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'file-verified',
      label: 'Confirm the test file appears in the intended service',
      status: fileTransferAvailable ? (manualChecks['file-verified'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'netbird-installed',
      label: 'Install NetBird on each device that needs access away from home',
      status: manualChecks['netbird-installed'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'netbird-enrolled',
      label: 'Ask an admin to enrol each NetBird device',
      status: manualChecks['netbird-enrolled'] ? 'manual' : 'pending',
      manual: true,
    },
    {
      id: 'netbird-tested',
      label: 'Turn off Wi-Fi and open one private service to test remote access',
      status: manualChecks['netbird-tested'] ? 'manual' : 'pending',
      manual: true,
    },
    ...optionalSetupItems,
    {
      id: 'optional-unavailable',
      label: 'No optional phone or media connections are assigned to this account',
      status: optionalSetupIds.length === 0 ? 'unavailable' : 'verified',
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
      <li key={item.id} class={{ 'setup-item': true, [item.status]: true, manual: item.manual && item.status !== 'unavailable' }}>
        {item.manual && item.status !== 'unavailable' ? <ManualCheck id={item.id} label={item.label} /> : <><StatusMark status={item.status} /><span>{item.label}</span></>}
      </li>
    );
  };

  const steps = [
    {
      id: 'welcome',
      label: 'Install a password manager',
      status: stepStatus(['manager-installed', 'manager-vault-created']),
      content: (
        <>
          <span class="eyebrow">Essential setup</span>
          <h1>Install a password manager</h1>
          <p class="step-lead">Start here so every password, recovery code, and app-specific login created later has a safe place to go.</p>
          <ul class="setup-list">{['manager-installed', 'manager-vault-created'].map(renderSetupItem)}</ul>
          <div class="getting-started-actions compact">
            <a class="primary-link" href="https://bitwarden.com/download/" target="_blank" rel="noreferrer">Download Bitwarden</a>
            <a class="secondary-link" href="https://keepassxc.org/download/" target="_blank" rel="noreferrer">Download KeePassXC</a>
          </div>
          <aside class="guide-callout neutral"><strong>Choose one.</strong> Bitwarden works across phones and computers and can connect to the server's Passwords service. KeePassXC keeps a local encrypted vault that you back up yourself.</aside>
        </>
      ),
      explain: {
        plain: (
          <>
            <p>A password manager keeps all of your passwords, recovery codes, and app-specific logins in one locked place, protected by a single master password that only you know.</p>
            <p>It stores a copy on your own devices, so you can still read your logins even if this server or its network goes offline. The later steps create logins — your sign-in, app passwords, recovery codes — and having a vault ready now gives each one a safe place to go.</p>
          </>
        ),
        technical: (
          <>
            <p>This server's Passwords service is Vaultwarden, a Bitwarden-compatible server. A local KeePassXC database is the no-server alternative.</p>
            <p>Vaultwarden is deliberately kept separate from the Kanidm SSO directory. That separation reduces the chance of accidental password access on an open desktop or phone, and your passwords stay reachable even if an issue with Kanidm arises. It also lets us set up passwords during initial bootstrapping of the server, before Kanidm admins and users have been created.</p>
            <p>Vaults are encrypted end-to-end: the server never sees your master password, so a server compromise does not expose vault contents.</p>
          </>
        ),
      },
    },
    {
      id: 'account',
      label: 'Activate your account',
      status: stepStatus(['account-profile-confirmed', 'account-password-set', 'account-second-factor', 'account-login-tested']),
      content: (
        <>
          <span class="eyebrow">Essential setup</span>
          <h1>Activate your account</h1>
          <p class="step-lead">Kanidm manages your account for Homepage and most services. You are currently signed in as <strong>{username}</strong>.</p>
          <ul class="setup-list">{['account-profile-confirmed', 'account-password-set', 'account-second-factor', 'account-login-tested'].map(renderSetupItem)}</ul>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
          </div>
          <aside class="guide-callout"><strong>One-time account links are short-lived.</strong> It works once and expires after one hour. If it expires, ask for a new link. Never send an admin your password, one-time link, passkey, authenticator code, or recovery code.</aside>
          <aside class="guide-callout neutral"><strong>Use a trusted network path.</strong> Open private services only on your home network or through NetBird. {serverLanHost ? <>If a service doesn't work at home, tell the admin you're reaching the server at <strong>{serverLanHost}</strong>.</> : "If a service doesn't work, tell the admin which network you're using."} Never bypass certificate warnings.</aside>
        </>
      ),
      explain: {
        plain: (
          <>
            <p>Kanidm is the single sign-in used by Homepage and most services. Activating your account makes it secure and verified, so every app knows it is really you.</p>
            <p>Adding a passkey or authenticator as a second sign-in method means that even if someone gets your password, they still cannot get in without one of your devices. A quick sign-out and sign-in test confirms everything works before you depend on it.</p>
          </>
        ),
        technical: (
          <>
            <p>Kanidm is the identity provider (IdP); Homepage and the OAuth2-protected services trust it, so one account covers the whole surface.</p>
            <p>The one-time enrollment link is single-use and expires after one hour. That prevents a stale link from being replayed to take over an account; if it expires, an admin must issue a new one.</p>
            <p>Credential policy favours passkeys (WebAuthn) as a phishing-resistant second factor over reusable codes. Recovery codes give you a way back in if you lose the device holding your passkey.</p>
            <p>Account group memberships determine which apps appear on your Services page, and a fresh sign-in refreshes those claims, so group changes take effect after the next login.</p>
          </>
        ),
      },
    },
    {
      id: 'recovery',
      label: 'Save recovery details',
      status: stepStatus(['recovery-login-saved', 'recovery-methods-saved', 'recovery-backup-saved']),
      content: (
        <>
          <span class="eyebrow">Essential setup</span>
          <h1>Save recovery details</h1>
          <p class="step-lead">Keep enough information outside this server to regain access if the server or one of your devices is unavailable.</p>
          <ul class="setup-list">{['recovery-login-saved', 'recovery-methods-saved', 'recovery-backup-saved'].map(renderSetupItem)}</ul>
          <div class="choice-grid" aria-label="Account types">
            <article>
              <strong>Kanidm sign-in</strong>
              <span>Used by Homepage and most apps. Add a second sign-in method.</span>
            </article>
            {passwordsStatus === 'available' && (
              <article>
                <strong>Passwords master password</strong>
                <span>Separate from Kanidm. The server cannot recover it, so save the master password and a recovery backup immediately.</span>
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
          <aside class="guide-callout neutral">Store recovery codes in a second secure location that does not depend on this server. Save app-specific passwords separately from your Kanidm password.</aside>
        </>
      ),
      explain: {
        plain: (
          <>
            <p>This step records what you need to get back into your account if a device is lost, broken, or the server is offline.</p>
            <p>Save your username and sign-in address, write down which devices hold your passkeys or authenticator, and keep a backup of your password vault somewhere that does not depend on this server — like a spare key kept away from the lock.</p>
          </>
        ),
        technical: (
          <>
            <p>Kanidm recovery relies on registered credentials (passkeys or authenticator) and the account recovery codes. If all of those are lost, only an admin can reset the account, so recording the devices and the sign-in address matters.</p>
            <p>The Vaultwarden master password can never be reset by anyone — the vault is encrypted end-to-end and the server never sees the master password. A personal export kept off-server is the only safety net for vault contents, which is why this step includes a recovery backup.</p>
            <p>Local Backups (Kopia) and Monitor (Beszel) use their own credentials, so a Kanidm compromise does not extend to encrypted backups or monitoring logins.</p>
            <p>Keep recovery codes in a second location that does not depend on this server, and save app-specific passwords separately from your Kanidm password.</p>
          </>
        ),
      },
    },
    {
      id: 'services',
      label: 'Open your services',
      status: serviceSetupIds.length > 0 ? stepStatus(serviceSetupIds) : 'unavailable',
      content: (
        <>
          <span class="eyebrow">Core services</span>
          <h1>Open your services</h1>
          <p class="step-lead">The Services page lists {enabledServices.length} app{enabledServices.length === 1 ? '' : 's'} assigned to your account. Open each service once and tick it off below. Most use the Kanidm sign-in you just set up; Passwords and the other separately noted apps have their own login.</p>
          {enabledServices.length > 0 && (
            <div class="available-service-list" aria-label="Available services">
              {enabledServices.map((service) => (
                <a key={service.id} href={service.url} target={service.url.startsWith('/') ? undefined : '_blank'} rel="noreferrer">{service.name}</a>
              ))}
            </div>
          )}
          {enabledServices.length > 0 ? (
            <ul class="setup-list">{serviceSetupIds.map(renderSetupItem)}</ul>
          ) : (
            <><ul class="setup-list">{['services-unavailable'].map(renderSetupItem)}</ul><aside class="guide-callout neutral">No enabled apps are currently assigned to this account, so there is nothing to check here. If you expected an app, sign out and back in once, then ask an admin to verify your access.</aside></>
          )}
          {(documentsStatus === 'available' || booksStatus === 'available') && (
            <aside class="guide-callout neutral">
              <strong>Some app accounts are created on first sign-in.</strong> {documentsStatus === 'available' && 'Documents'}{documentsStatus === 'available' && booksStatus === 'available' && ' and '}{booksStatus === 'available' && 'Books'} may need a moment to create a local profile. Try once before reporting issues.
            </aside>
          )}
          {passwordsStatus === 'available' && (
            <aside class="guide-callout">
              <strong>Passwords is separate from Kanidm.</strong> It uses its own vault and master password, not your Kanidm password. On the first visit, register with your local account email. If that email is already registered, sign in with the Vaultwarden master password instead — don't create a second vault. An admin can't recover a lost master password.
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
            <strong>If access was just changed, refresh your sign-in first.</strong> Sign out and back in to refresh account groups. If the service is still missing, ask an admin to verify membership.
          </aside>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">Open Services</Link>
          </div>
        </>
      ),
      explain: {
        plain: (
          <>
            <p>This step opens every app assigned to your account once, so first-time setup happens and you can confirm each one works for you.</p>
            <p>Some apps create your local profile the first time you sign in, so give them a moment before reporting a problem.</p>
          </>
        ),
        technical: (
          <>
            <p>Apps sit behind the auth gateway and reuse the Kanidm session via OAuth2/OIDC, so you do not manage separate credentials for each service. Passwords (Vaultwarden) is the deliberate exception: it is not behind the gateway, so its self-service vault and master password stay reachable independently of Kanidm.</p>
            <p>Some apps (Documents, Books) provision a local profile on first successful sign-in; a blank or slow first load is expected behaviour.</p>
            <p>Backups (Kopia) and Monitor (Beszel) have two sign-in gates: a Kanidm group check, then an app-level credential. A failure at the second gate is not fixed by resetting Kanidm.</p>
            <p>If access was just granted, sign out and back in to refresh the session's group claims before asking an admin to investigate.</p>
          </>
        ),
      },
    },
    {
      id: 'uploads',
      label: 'Add your files',
      status: stepStatus(['file-destinations-reviewed', 'file-transferred', 'file-verified']),
      content: (
        <>
          <span class="eyebrow">Files</span>
          <h1>Add your files</h1>
          <p class="step-lead">{filesWebAvailable ? 'Use the Files web app for small uploads.' : 'Browser file uploads are not available.'} {sftpAvailable ? 'For regular or large transfers, connect via SSHFS.' : 'SFTP/SSHFS is not enabled for your account.'}</p>
          <ul class="setup-list">{['file-destinations-reviewed', 'file-transferred', 'file-verified'].map(renderSetupItem)}</ul>
          {fileTransferAvailable ? (
            <>
              <div class="choice-grid">
                {filesWebAvailable && <article><strong>Upload in browser</strong><span>Open Files, choose the folder, and drag files in.</span></article>}
                {sftpAvailable && <article><strong>Connect via SSHFS</strong><span>Mount the server as a folder. Follow the home-network-only guide for your OS.</span></article>}
              </div>
              <aside class="guide-callout neutral"><strong>Browser Files and SFTP/SSHFS are separate permissions.</strong> SFTP uses a device key and is only available on the home network. Do not upload the same file to multiple folders because that creates duplicates.</aside>
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
      explain: {
        plain: (
          <>
            <p>This step moves one small test file to the server so you can see exactly where it lands and confirm everything works before you move the rest of your files.</p>
            <p>Follow the Detailed Guide for the correct destination folder so your files end up where you expect them to be.</p>
          </>
        ),
        technical: (
          <>
            <p>Two separate transfer paths exist: the Files web app (Filestash) for small in-browser uploads, and SFTP/SSHFS for large or regular transfers.</p>
            <p>SFTP authenticates with a device key and is only exposed on the home network, so it is not reachable from outside your LAN.</p>
            <p>Destination folders map to specific app import directories (for example the photo library or audiobooks library). Uploading the same file into multiple folders creates duplicates, because nothing deduplicates across destinations.</p>
            <p>Browser Files and SFTP are separate permissions — having one does not imply the other.</p>
          </>
        ),
      },
    },
    {
      id: 'devices',
      label: 'Set up access away from home',
      status: stepStatus(['netbird-installed', 'netbird-enrolled', 'netbird-tested']),
      content: (
        <>
          <span class="eyebrow">Optional access</span>
          <h1>Set up access away from home</h1>
          <p class="step-lead">Skip this step if you only use the server at home. Otherwise, use NetBird for private access from another network.</p>
          <ul class="setup-list">{['netbird-installed', 'netbird-enrolled', 'netbird-tested'].map(renderSetupItem)}</ul>
          <div class="getting-started-actions compact">
            <a class="primary-link" href="https://docs.netbird.io/get-started/install" target="_blank" rel="noreferrer">Download NetBird</a>
          </div>
          <aside class="guide-callout neutral">Ask an admin to enrol the device after installation. Never expose a private service directly, use a public share hostname as an app login, or bypass a certificate warning.</aside>
        </>
      ),
      explain: {
        plain: (
          <>
            <p>Skip this step if you only use the server at home. Otherwise, NetBird connects your devices to the server through a private, encrypted tunnel, so you can use it from anywhere without opening it to the public internet.</p>
            <p>An admin enrols each device after you install it, which keeps device access controlled.</p>
          </>
        ),
        technical: (
          <>
            <p>NetBird builds a private WireGuard-based mesh overlay; only enrolled devices can resolve and reach the private service hostnames. This keeps private endpoints off the public internet.</p>
            <p>The public edge (Caddy/Cloudflare) only publishes the approved public share hostnames, so public exposure is limited by design.</p>
            <p>Never expose a private service directly or bypass a certificate warning — the threat model depends on private endpoints staying off the public internet. Enrolment is an admin action so device join is deliberate and auditable.</p>
          </>
        ),
      },
    },
    {
      id: 'finish',
      label: 'Connect optional apps',
      status: optionalSetupIds.length > 0 ? stepStatus(optionalSetupIds) : 'unavailable',
      content: (
        <>
          <span class="eyebrow">Optional apps · final step</span>
          <h1>Connect optional apps</h1>
          <p class="step-lead">Set up only the phone and media clients for services assigned to you. This final step covers Immich, Jellyfin, Inkita, Lissen, and Audiobookshelf.</p>
          <ul class="setup-list">{(optionalSetupIds.length > 0 ? optionalSetupIds : ['optional-unavailable']).map(renderSetupItem)}</ul>
          <div class="device-setup-list">
            {photosStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Photos</span><h3>Back up phone photos with Immich</h3></div>
                <p>Install Immich, enter <strong>{photosUrl}</strong>, select albums to back up, and allow photo and background permissions. Do not use a public photo-share link or the public share hostname as the server address.</p>
                <div class="getting-started-actions compact">
                  <a class="secondary-link" href="https://docs.immich.app/overview/quick-start/#download-the-mobile-app" target="_blank" rel="noreferrer">Download Immich</a>
                  <a class="secondary-link" href={photosUrl} target="_blank" rel="noreferrer">Open Photos</a>
                </div>
              </article>
            )}
            {videosStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Videos</span><h3>Watch with Jellyfin</h3></div>
                <p>Install the client for your phone, TV, or computer and connect it to <strong>{videosUrl}</strong>. Use Quick Connect, or ask an admin for the initial Jellyfin password, change it on first sign-in, and save the new one.</p>
                <div class="getting-started-actions compact">
                  <a class="secondary-link" href="https://jellyfin.org/downloads/" target="_blank" rel="noreferrer">Download Jellyfin</a>
                  <a class="secondary-link" href={videosUrl} target="_blank" rel="noreferrer">Open Videos</a>
                </div>
              </article>
            )}
            {booksStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Books</span><h3>Read with Inkita on Android</h3></div>
                <p>Install Inkita, connect it to <strong>{booksUrl}</strong>, and open a test book before downloading anything for offline reading.</p>
                <div class="getting-started-actions compact">
                  <a class="secondary-link" href="https://github.com/dom-53/Inkita" target="_blank" rel="noreferrer">Download Inkita</a>
                  <a class="secondary-link" href={booksUrl} target="_blank" rel="noreferrer">Open Books</a>
                </div>
              </article>
            )}
            {audiobooksStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Audiobooks</span><h3>Listen with Lissen or Audiobookshelf</h3></div>
                <p>Install one Android client, connect it to <strong>{audiobooksUrl}</strong>, and play a test chapter before downloading books.</p>
                <div class="getting-started-actions compact">
                  <a class="secondary-link" href="https://f-droid.org/en/packages/org.grakovne.lissen/" target="_blank" rel="noreferrer">Download Lissen</a>
                  <a class="secondary-link" href="https://github.com/advplyr/audiobookshelf-app" target="_blank" rel="noreferrer">Download Audiobookshelf</a>
                  <a class="secondary-link" href={audiobooksUrl} target="_blank" rel="noreferrer">Open Audiobooks</a>
                </div>
              </article>
            )}
            {offlineMediaStatus === 'available' && (
              <article>
                <div><span class="eyebrow">Offline Media</span><h3>Sync media with Syncthing-Fork</h3></div>
                <p>Install Syncthing-Fork on Android, copy its device ID, then enrol the device. Accept every shared folder as <strong>Receive Only</strong>. iPhone and iPad are not supported.</p>
                <div class="getting-started-actions compact">
                  <a class="secondary-link" href="https://f-droid.org/en/packages/com.github.catfriend1.syncthingfork/" target="_blank" rel="noreferrer">Download Syncthing-Fork</a>
                  <Link class="secondary-link" href="/services/offline-media">Set up Offline Media</Link>
                </div>
              </article>
            )}
          </div>
          <div class="finish-next-steps">
            <h3>Where to go next</h3>
            <p>Use <strong>Services</strong> to open apps. {fileTransferAvailable && <><strong>Detailed Guide</strong> covers app features and file destinations. </>}Return to this checklist whenever you add a device.</p>
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
      explain: {
        plain: (
          <>
            <p>This last step connects your phone and media apps to the server: photo backup, video watching, books, audiobooks, and offline media sync. Only do the ones you will actually use.</p>
          </>
        ),
        technical: (
          <>
            <p>Each optional client connects over the private network or the app's assigned hostname. Where supported, apps reuse the Kanidm session for sign-in.</p>
            <p>Photos (Immich) backs up from your phone; Videos (Jellyfin) uses seeded household accounts; Books (Inkita) and Audiobooks (Lissen or Audiobookshelf) attach to their libraries.</p>
            <p>Jellyfin supports Quick Connect to avoid sharing a password; otherwise the bootstrap password should be changed on first sign-in and saved in your password manager.</p>
            <p>Offline Media (Syncthing-Fork) replicates folders as Receive Only to mirror media onto the device for offline use; iPhone and iPad are not supported.</p>
          </>
        ),
      },
    },
  ] satisfies { id: GettingStartedStepId; label: string; status: SetupStatus; content: JSXOutput; explain: { plain: JSXOutput; technical: JSXOutput } }[];

  const activeStepIndex = steps.findIndex((step) => step.id === activeStepId);
  const activeStep = steps[activeStepIndex] ?? steps[0];
  const relevantItems = setupItems.filter((item) => item.status !== 'unavailable' && !item.id.endsWith('-unavailable'));
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
