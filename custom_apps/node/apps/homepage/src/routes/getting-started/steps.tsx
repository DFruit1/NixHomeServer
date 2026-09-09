import type { JSXOutput } from '@builder.io/qwik';
import { $ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { CredentialBackupGuide } from '../../components/CredentialBackupGuide.js';
import { SftpSetup } from '../../components/SftpSetup.js';
import type { ServiceCard } from '../../shared/types.js';
import type { GettingStartedStepId, SetupItem, SetupStatus } from './setup-model.js';
import { statusLabel, stepStatus } from './setup-model.js';

export type StepsContext = {
  username: string;
  domain: string;
  serverLanHost?: string;
  kanidmUrl: string;
  filesUrl: string;
  passwordsUrl: string;
  photosUrl: string;
  videosUrl: string;
  booksUrl: string;
  audiobooksUrl: string;
  statuses: {
    passwords: SetupStatus;
    files: SetupStatus;
    photos: SetupStatus;
    videos: SetupStatus;
    documents: SetupStatus;
    books: SetupStatus;
    audiobooks: SetupStatus;
    backups: SetupStatus;
    monitor: SetupStatus;
    offlineMedia: SetupStatus;
  };
  filesWebAvailable: boolean;
  sftpAvailable: boolean;
  fileTransferAvailable: boolean;
  sftp: NonNullable<import('../../shared/types.js').HomepageData['sftp']>;
  enabledServices: ServiceCard[];
  setupItems: SetupItem[];
  serviceSetupIds: string[];
  optionalSetupIds: string[];
  manualChecks: Record<string, boolean>;
  setManualCheck: (id: string, checked: boolean) => void;
};

export type GettingStartedStep = {
  id: GettingStartedStepId;
  label: string;
  status: SetupStatus;
  content: JSXOutput;
  explain: { plain: JSXOutput; technical: JSXOutput };
};

export const StatusMark = ({ status, decorative = false }: { status: SetupStatus; decorative?: boolean }) => (
  <span class={{ 'setup-status': true, [status]: true }} aria-label={decorative ? undefined : statusLabel(status)} aria-hidden={decorative ? 'true' : undefined}>
    {status === 'verified' || status === 'manual' ? <>&#10003;</> : ''}
  </span>
);

const ManualCheck = ({ id, label, checked, setManualCheck }: { id: string; label: string; checked: boolean; setManualCheck: (id: string, checked: boolean) => void }) => (
  <label class="manual-check">
    <input
      type="checkbox"
      checked={Boolean(checked)}
      onChange$={(_event, target) => setManualCheck(id, target.checked)}
    />
    <span>{label}</span>
  </label>
);

export const buildSteps = (ctx: StepsContext): GettingStartedStep[] => {
  const {
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
      videos: videosStatus,
      photos: photosStatus,
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
    sftp,
    enabledServices,
    setupItems,
    manualChecks,
    setManualCheck,
  } = ctx;

  const renderSetupItem = (id: string) => {
    const item = setupItems.find((candidate) => candidate.id === id);
    if (!item) return null;
    return (
      <li key={item.id} class={{ 'setup-item': true, [item.status]: true, manual: item.manual && item.status !== 'unavailable' }}>
        {item.manual && item.status !== 'unavailable'
          ? <ManualCheck id={item.id} label={item.label} checked={Boolean(manualChecks[item.id])} setManualCheck={setManualCheck} />
          : <><StatusMark status={item.status} /><span>{item.label}</span></>}
      </li>
    );
  };

  return [
    {
      id: 'welcome',
      label: 'Install a password manager',
      status: stepStatus(setupItems, ['manager-installed', 'manager-vault-created']),
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
      status: stepStatus(setupItems, ['account-profile-confirmed', 'account-password-set', 'account-second-factor', 'account-login-tested']),
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
      status: stepStatus(setupItems, ['recovery-login-saved', 'recovery-methods-saved', 'recovery-backup-saved']),
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
      status: ctx.serviceSetupIds.length > 0 ? stepStatus(setupItems, ctx.serviceSetupIds) : 'unavailable',
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
            <ul class="setup-list">{ctx.serviceSetupIds.map(renderSetupItem)}</ul>
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
      status: stepStatus(setupItems, ['file-destinations-reviewed', 'file-transferred', 'file-verified']),
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
                  sftp={sftp}
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
      status: stepStatus(setupItems, ['netbird-installed', 'netbird-enrolled', 'netbird-tested']),
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
      status: ctx.optionalSetupIds.length > 0 ? stepStatus(setupItems, ctx.optionalSetupIds) : 'unavailable',
      content: (
        <>
          <span class="eyebrow">Optional apps · final step</span>
          <h1>Connect optional apps</h1>
          <p class="step-lead">Set up only the phone and media clients for services assigned to you. This final step covers Immich, Jellyfin, Inkita, Lissen, and Audiobookshelf.</p>
          <ul class="setup-list">{(ctx.optionalSetupIds.length > 0 ? ctx.optionalSetupIds : ['optional-unavailable']).map(renderSetupItem)}</ul>
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
  ];
};
