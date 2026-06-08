import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import QRCode from 'qrcode';
import type { QRL } from '@builder.io/qwik';
import type { AdminStep, FolderGuide, HomepageData, PhoneBackupSetup, ServiceCard, SftpKeyResponse } from './shared/types.js';
import './client/styles.css';

type NavigateHandler = QRL<(nextPath: string, replace?: boolean) => void>;
type ToggleHandler = QRL<() => void>;
type ImageChangeHandler = QRL<(event: Event, target: HTMLInputElement) => void>;

const serviceSymbols: Record<string, string> = {
  photos: 'P',
  documents: 'D',
  files: 'F',
  audiobooks: 'A',
  videos: 'V',
  books: 'B',
  wiki: 'W',
  emails: 'M',
  downloads: 'Y',
  passwords: 'K',
  backups: 'R',
  sftp: 'S',
};

const serviceTips: Record<string, string[]> = {
  photos: [
    'Use the Immich mobile app for camera-roll backup and the web UI for album management.',
    'Share links should come from the public share host; normal browsing should stay on the private Photos host.',
  ],
  documents: [
    'Paperless works best with PDFs and image documents. Convert office files before adding them.',
    'Mail Archive can send selected attachments directly into the Paperless consume flow.',
  ],
  files: [
    'Files is the easiest place to upload general content before moving it into app-specific folders.',
    'Direct SFTP is better for large uploads after your public key is installed.',
  ],
  audiobooks: [
    'Keep one book per folder and keep cover art beside the audio files.',
    'Downloader audio belongs under _Audiobooks/_YouTube.',
  ],
  videos: [
    'Use _Movies for films, _Shows for series, _Home for personal video, _Music-videos for music clips, and _YouTube for downloaded video.',
    'Keep subtitle files beside the matching video file.',
  ],
  books: [
    'Use _Ebooks for prose, _Comics for comics, and _Manga for manga.',
    'CBZ and CBR are preferred for comics and manga archives.',
  ],
  wiki: [
    'Only complete .zim files should go into the Kiwix library.',
    'The server regenerates the Kiwix catalog after uploads.',
  ],
  emails: [
    'Use the Mail Archive UI for search, attachment downloads, and reindex actions.',
    'Do not work inside .internal-sync; it is internal app state.',
  ],
  downloads: [
    'Choose personal output for your own library or shared output when the media should appear for everyone.',
    'Audio and video outputs are routed into the matching media folders.',
  ],
  passwords: [
    'Vaultwarden uses its own local login after an admin invite.',
    'Store Kanidm recovery codes and app-local passwords here.',
  ],
  backups: [
    'Kopia browser access is separately protected and still needs the native Kopia password.',
    'Use this only for backup administration and restore checks.',
  ],
  sftp: [
    'Generate an SFTP key pair, upload the public key, then connect from your file explorer or SSH client.',
    'Use port 2222 on server.home.arpa for the SSH/SFTP endpoint.',
  ],
};

const readRoute = (): { path: string; guide?: string } => ({
  path: window.location.pathname,
  guide: new URLSearchParams(window.location.search).get('guide') ?? undefined,
});

export default component$(() => {
  const data = useSignal<HomepageData | undefined>();
  const error = useSignal('');
  const path = useSignal('/');
  const activeGuide = useSignal('documents');
  const publicKey = useSignal('');
  const keyStatus = useSignal('');
  const keyStatusKind = useSignal<'success' | 'error'>('success');
  const keySubmitting = useSignal(false);
  const profileOpen = useSignal(false);
  const profileImage = useSignal('');

  useVisibleTask$(({ cleanup }) => {
    const syncRoute = () => {
      const route = readRoute();
      path.value = route.path;
      if (route.guide) {
        activeGuide.value = route.guide;
      }
    };
    syncRoute();
    window.addEventListener('popstate', syncRoute);
    cleanup(() => window.removeEventListener('popstate', syncRoute));

    profileImage.value = window.localStorage.getItem('homepage.profileImage') ?? '';

    fetch('/api/home')
      .then(async (response) => {
        if (!response.ok) {
          throw new Error('Sign-in is required');
        }
        data.value = (await response.json()) as HomepageData;
      })
      .catch((caught) => {
        error.value = caught instanceof Error ? caught.message : String(caught);
      });
  });

  const navigate = $((nextPath: string, replace = false) => {
    const next = new URL(nextPath, window.location.href);
    if (replace) {
      window.history.replaceState(null, '', `${next.pathname}${next.search}`);
    } else {
      window.history.pushState(null, '', `${next.pathname}${next.search}`);
    }
    path.value = next.pathname;
    const requestedGuide = next.searchParams.get('guide');
    if (requestedGuide) {
      activeGuide.value = requestedGuide;
    }
  });

  const submitKey = $(async (event?: Event) => {
    event?.preventDefault();
    if (!publicKey.value.trim() || keySubmitting.value) {
      return;
    }
    keyStatus.value = '';
    keySubmitting.value = true;
    try {
      const response = await fetch('/api/sftp-key', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ publicKey: publicKey.value }),
      });
      const body = (await response.json().catch(() => ({}))) as Partial<SftpKeyResponse> & { error?: string };
      if (!response.ok || body.ok === false) {
        throw new Error(body.error || 'Public key could not be saved');
      }
      publicKey.value = '';
      keyStatusKind.value = 'success';
      keyStatus.value = body.details ? `${body.message || 'SFTP public key saved.'} ${body.details}` : body.message || 'SFTP public key saved.';
    } catch (caught) {
      keyStatusKind.value = 'error';
      keyStatus.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      keySubmitting.value = false;
    }
  });

  const enabledServices = data.value?.services.filter((service) => service.enabled) ?? [];
  const disabledServices = data.value?.services.filter((service) => !service.enabled) ?? [];
  const guide = data.value?.folderGuides.find((item) => item.id === activeGuide.value) ?? data.value?.folderGuides[0];
  const user = data.value?.user;
  const isUploads = path.value.startsWith('/uploads');
  const isGettingStarted = path.value.startsWith('/getting-started');
  const isAdmins = path.value.startsWith('/admins');
  const serviceId = path.value.match(/^\/services\/([^/?#]+)/)?.[1];
  const detailService = serviceId ? enabledServices.find((service) => service.id === decodeURIComponent(serviceId)) : undefined;
  const isServiceDetail = Boolean(serviceId);
  const domain = data.value?.domain ?? 'sydneybasiniot.org';
  const title = isUploads
    ? 'How to Upload Files'
    : isGettingStarted
      ? 'Getting Started'
      : isAdmins
        ? 'For Admins'
        : detailService
          ? detailService.name
          : 'Home';
  const showPageTitle = isUploads || isGettingStarted || isAdmins;

  const updateProfileImage = $(async (_event: Event, target: HTMLInputElement) => {
    const file = target.files?.[0];
    if (!file || !file.type.startsWith('image/')) {
      return;
    }
    if (file.size > 2 * 1024 * 1024) {
      return;
    }
    const reader = new FileReader();
    reader.addEventListener('load', () => {
      if (typeof reader.result !== 'string') {
        return;
      }
      profileImage.value = reader.result;
      window.localStorage.setItem('homepage.profileImage', reader.result);
    });
    reader.readAsDataURL(file);
  });

  const clearProfileImage = $(() => {
    profileImage.value = '';
    window.localStorage.removeItem('homepage.profileImage');
  });

  return (
    <main class="shell">
      <header class={{ topbar: true, compact: !showPageTitle }}>
        {showPageTitle && (
          <div>
            <p class="eyebrow">Sydney Basin Services</p>
            <h1>{title}</h1>
          </div>
        )}
        <ProfileMenu
          image={profileImage.value}
          open={profileOpen.value}
          username={user?.username ?? 'Loading'}
          onToggle$={() => (profileOpen.value = !profileOpen.value)}
          onImageChange$={updateProfileImage}
          onImageClear$={clearProfileImage}
        />
      </header>

      {error.value && <p class="notice">{error.value}</p>}

      <nav class="tabs" aria-label="Homepage sections">
        <a class={{ selected: !isUploads && !isServiceDetail && !isGettingStarted && !isAdmins }} href="/" onClick$={(event) => { event.preventDefault(); navigate('/'); }}>
          Services
        </a>
        <a class={{ selected: isGettingStarted }} href="/getting-started" onClick$={(event) => { event.preventDefault(); navigate('/getting-started'); }}>
          Getting Started
        </a>
        <a class={{ selected: isUploads }} href="/uploads" onClick$={(event) => { event.preventDefault(); navigate('/uploads'); }}>
          How to Upload Files
        </a>
        <a class={{ selected: isAdmins }} href="/admins" onClick$={(event) => { event.preventDefault(); navigate('/admins'); }}>
          For Admins
        </a>
      </nav>

      {isGettingStarted && <GettingStarted data={data.value} onNavigate$={navigate} />}

      {isAdmins && (
        <AdminPage adminGuide={data.value?.adminGuide ?? []} />
      )}

      {isServiceDetail && (
        <section class="section">
          {detailService ? (
            <ServiceDetail service={detailService} phoneBackup={data.value?.phoneBackup} domain={domain} username={user?.username} />
          ) : (
            <div class="empty-state">
              <h2>Service Not Found</h2>
              <p>This service is not enabled or is not available in the current server build.</p>
              <a class="open-link" href="/" onClick$={(event) => { event.preventDefault(); navigate('/'); }}>
                Back to services
              </a>
            </div>
          )}
        </section>
      )}

      {!isUploads && !isServiceDetail && !isGettingStarted && !isAdmins && (
        <>
          <section class="section">
            <div class="section-heading">
              <h2>Services</h2>
            </div>
            <div class="service-grid">
              {enabledServices.map((service) => (
                <ServiceTile key={service.id} service={service} onNavigate$={navigate} />
              ))}
            </div>
            {disabledServices.length > 0 && (
              <div class="disabled-list">
                <h3>Not enabled</h3>
                <p>{disabledServices.map((service) => service.name).join(', ')}</p>
              </div>
            )}
          </section>

          <section class="section two-column">
            <div>
              <h2>First Sign-In</h2>
              <ol class="steps">
                <li>Open Kanidm from any app sign-in button and set your password plus MFA.</li>
                <li>Use Files for general uploads, then place media in the app-specific folders.</li>
                <li>Open each app once after access is granted so its local account can be created.</li>
                <li>Use Passwords only after an admin sends a Vaultwarden invite.</li>
              </ol>
            </div>
            <div class="folder-card">
              <h2>My Folders</h2>
              <dl>
                <div>
                  <dt>Files</dt>
                  <dd>/mnt/data/users/{user?.username ?? '{username}'}</dd>
                </div>
                <div>
                  <dt>Browser</dt>
                  <dd>https://files.{domain}</dd>
                </div>
                <div>
                  <dt>SFTP</dt>
                  <dd>sftp://{user?.username ?? '{username}'}@server.home.arpa:2222/</dd>
                </div>
              </dl>
            </div>
          </section>
        </>
      )}

      {isUploads && (
        <>
          <section class="section upload-layout">
            <aside class="guide-list">
              {(data.value?.folderGuides ?? []).map((item) => (
                <a
                  key={item.id}
                  href={`/uploads?guide=${encodeURIComponent(item.id)}`}
                  class={{ selected: activeGuide.value === item.id }}
                  data-guide-id={item.id}
                  onClick$={(event, target) => {
                    event.preventDefault();
                    activeGuide.value = target.dataset.guideId ?? item.id;
                    navigate(`/uploads?guide=${encodeURIComponent(activeGuide.value)}`, true);
                  }}
                >
                  <span>{item.title}</span>
                  <small>{item.enabled ? 'Enabled' : 'Not enabled'}</small>
                </a>
              ))}
            </aside>
            {guide && <GuidePanel guide={guide} username={user?.username ?? '{username}'} />}
          </section>

          <section class="section two-column">
            <SftpSetup username={user?.username ?? '{username}'} domain={domain} />
            <form class="key-form" preventdefault:submit onSubmit$={submitKey}>
              <h2>Upload SFTP Public Key</h2>
              <p>
                Paste one OpenSSH public key. Saving replaces your current direct-SFTP key file on the server.
              </p>
              <textarea
                value={publicKey.value}
                onInput$={(_, target) => (publicKey.value = target.value)}
                placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop"
                rows={5}
              />
              <button type="submit" disabled={keySubmitting.value}>
                {keySubmitting.value ? 'Saving...' : 'Save Public Key'}
              </button>
              {keyStatus.value && <p class={{ 'key-status': true, error: keyStatusKind.value === 'error' }}>{keyStatus.value}</p>}
            </form>
            <section class="detail-block">
              <h3>Connect using a file explorer</h3>
              <p>After you upload your public key, connect with one of these common clients:</p>
              <SftpAccessInstructions username={user?.username ?? '{username}'} />
            </section>
          </section>

        </>
      )}

    </main>
  );
});

export const GettingStarted = component$(({ data, onNavigate$ }: { data?: HomepageData; onNavigate$: NavigateHandler }) => {
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const serviceUrl = (id: string, fallback: string) => data?.services.find((service) => service.id === id && service.enabled)?.url ?? fallback;
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const audiobooksUrl = serviceUrl('audiobooks', `https://audiobooks.${domain}/audiobookshelf/`);
  const videosUrl = serviceUrl('videos', `https://videos.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const syncthingAddresses = data?.phoneBackup?.connectionAddresses ?? [];

  return (
    <>
      <section class="section two-column">
        <div>
          <div class="section-heading stacked">
            <h2>Connect Your Devices</h2>
            <p>Set up account access first, then install the phone apps that make private access and media sync work smoothly.</p>
          </div>
          <ol class="steps">
            <li>Open any service and sign in with Kanidm. Finish password setup and MFA before configuring phone apps.</li>
            <li>Install NetBird on your phone for private network access away from home, then sign in or use the invite flow from the admin.</li>
            <li>Keep the normal web addresses for day-to-day use. Use NetBird when you are away from home or when a private-only service cannot be reached directly.</li>
            <li>Install only the app clients you actually use. Every app can also be opened in a browser from the Services page.</li>
          </ol>
        </div>
        <div class="folder-card">
          <h2>Network Addresses</h2>
          <dl>
            <div>
              <dt>Homepage</dt>
              <dd>https://homepage.{domain}</dd>
            </div>
            <div>
              <dt>Home LAN Server</dt>
              <dd>server.home.arpa</dd>
            </div>
            {syncthingAddresses.map((address) => (
              <div key={address}>
                <dt>{address.includes('100.') ? 'NetBird Syncthing' : 'LAN Syncthing'}</dt>
                <dd>{address}</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <section class="section">
        <div class="section-heading">
          <h2>Phone Apps</h2>
          <p>Install these when you want native app behavior instead of browser access.</p>
        </div>
        <div class="app-setup-grid">
          <AppSetupCard
            title="NetBird"
            platform="iOS / Android"
            url="https://docs.netbird.io/get-started/install/mobile"
            detail="Private mesh-network access for the server when you are not on the home LAN."
            steps={[
              'Install the NetBird mobile app.',
              'Sign in or use the setup flow provided by the admin.',
              'Leave NetBird connected before opening private server apps away from home.',
            ]}
            onNavigate$={onNavigate$}
          />
          <AppSetupCard
            title="Immich"
            platform="iOS / Android"
            url={photosUrl}
            detail="Native photo browsing and camera-roll backup."
            steps={[
              `Use ${photosUrl} as the server endpoint.`,
              'Sign in with Kanidm.',
              'Choose the albums to back up before enabling automatic backup.',
            ]}
            onNavigate$={onNavigate$}
          />
          <AppSetupCard
            title="Syncthing-Fork"
            platform="Android"
            url="/services/backups"
            detail="Copies the encrypted phone-backup repository from the server to your phone."
            steps={[
              'Open the Backups service details page.',
              'Scan the Server Device ID and Folder ID QR codes.',
              'Accept the folder as receive-only on the phone.',
            ]}
            onNavigate$={onNavigate$}
          />
          <AppSetupCard
            title="Bitwarden"
            platform="iOS / Android"
            url={passwordsUrl}
            detail="Mobile client for the Passwords service."
            steps={[
              'Install Bitwarden from the app store.',
              `Choose self-hosted server and enter ${passwordsUrl}.`,
              'Sign in after an admin has sent your Vaultwarden invite.',
            ]}
            onNavigate$={onNavigate$}
          />
          <AppSetupCard
            title="Audiobookshelf"
            platform="Android / web"
            url={audiobooksUrl}
            detail="Native or browser listening for audiobooks and podcasts."
            steps={[
              `Use ${audiobooksUrl} as the server address.`,
              'Sign in with Kanidm if prompted.',
              'Use offline downloads only for books you want stored on the device.',
            ]}
            onNavigate$={onNavigate$}
          />
          <AppSetupCard
            title="Jellyfin"
            platform="iOS / Android / TV"
            url={videosUrl}
            detail="Native clients for videos on phones, tablets, TVs, and streaming devices."
            steps={[
              `Use ${videosUrl} as the server address.`,
              'Sign in with your Jellyfin account.',
              'Use NetBird first if the app cannot reach the server from outside home.',
            ]}
            onNavigate$={onNavigate$}
          />
        </div>
      </section>

      <section class="section two-column">
        <div>
          <h2>Files And Uploads</h2>
          <ol class="steps">
            <li>Use Files in the browser for normal uploads: {filesUrl}.</li>
            <li>Use How to Upload Files when you need the exact media folder for documents, books, videos, or audiobooks.</li>
            <li>Use direct SFTP only for large or repeated uploads after saving your public key on the upload page.</li>
          </ol>
        </div>
        <div>
          <h2>Passwords And Recovery</h2>
          <ol class="steps">
            <li>Store app-local passwords, recovery codes, and server notes in Passwords after your invite is accepted.</li>
            <li>Keep Kanidm recovery codes somewhere you can still reach if the server or phone is unavailable.</li>
            <li>Ask an admin before deleting synced backup or media folders from a phone app.</li>
          </ol>
        </div>
      </section>
    </>
  );
});

export const AppSetupCard = component$(
  ({
    title,
    platform,
    url,
    detail,
    steps,
    onNavigate$,
  }: {
    title: string;
    platform: string;
    url: string;
    detail: string;
    steps: string[];
    onNavigate$: NavigateHandler;
  }) => (
    <article class="app-setup-card">
      <div>
        <h3>{title}</h3>
        <span>{platform}</span>
      </div>
      <p>{detail}</p>
      <ol class="steps">
        {steps.map((step) => (
          <li key={step}>{step}</li>
        ))}
      </ol>
      <a
        class="open-link"
        href={url}
        onClick$={(event) => {
          if (!url.startsWith('/')) {
            return;
          }
          event.preventDefault();
          onNavigate$(url);
        }}
      >
        Open setup
      </a>
    </article>
  ),
);

export const AdminPage = component$(({ adminGuide }: { adminGuide: AdminStep[] }) => (
  <>
    <section class="section">
      <div class="section-heading">
        <h2>Server Bootstrap</h2>
        <p>Operator checklist for a new host or a routine guarded deploy.</p>
      </div>
      <ol class="admin-steps">
        {adminGuide.map((step) => (
          <li key={step.title}>
            <h3>{step.title}</h3>
            <p>{step.detail}</p>
            {step.command && <code>{step.command}</code>}
          </li>
        ))}
      </ol>
    </section>
    <section class="section">
      <div class="section-heading stacked">
        <h2>New User Onboarding</h2>
        <p>Create identity first, grant only the access groups needed, then hand off first-sign-in and app setup.</p>
      </div>
      <ol class="admin-steps">
        <li>
          <h3>Create the Kanidm account</h3>
          <p>Use the guided admin tool or create the account directly with a username, display name, and primary email.</p>
          <code>kanidm-admin user create "$NEW_USER" --display-name "$DISPLAY_NAME" --email "$EMAIL"</code>
        </li>
        <li>
          <h3>Grant baseline access</h3>
          <p>Add the account to the baseline users group, then add only the app, file, or admin groups the person should have.</p>
          <code>kanidm-admin membership add "$NEW_USER" users</code>
        </li>
        <li>
          <h3>Add file access when needed</h3>
          <p>Use user-files for browser Files access, files-sftp-users for direct SFTP, and files-shared-users for the shared folder view.</p>
          <code>kanidm-admin membership add "$NEW_USER" user-files files-sftp-users files-shared-users</code>
        </li>
        <li>
          <h3>Invite password-manager users</h3>
          <p>Vaultwarden is local-auth only, so invite the Kanidm primary email when the person should use Passwords.</p>
          <code>kanidm-admin local vaultwarden invite "$NEW_USER"</code>
        </li>
        <li>
          <h3>Create the first sign-in link</h3>
          <p>Generate a short-lived reset link and share it only through a secure channel so the person can set credentials and MFA.</p>
          <code>kanidm-admin user reset-token "$NEW_USER" --ttl 3600</code>
        </li>
        <li>
          <h3>Hand off first sign-in</h3>
          <p>Ask the person to complete Kanidm password and MFA setup, open each granted app once, and save recovery details securely.</p>
        </li>
      </ol>
    </section>
    <section class="section two-column">
      <div>
        <h2>Daily Operations</h2>
        <ol class="steps">
          <li>Use the guarded deploy helper for rebuild tests and switches.</li>
          <li>Check failed systemd units before switching after a test deploy.</li>
          <li>Keep generated secrets encrypted in agenix and do not commit plaintext secret material.</li>
        </ol>
      </div>
      <div>
        <h2>User Support</h2>
        <ol class="steps">
          <li>Grant users the right Kanidm groups before asking them to open apps.</li>
          <li>For phone backup, configure the phone Syncthing device ID before enabling the phone-backup module.</li>
          <li>Use the Backups service page to help users scan the server Syncthing details.</li>
        </ol>
      </div>
    </section>
  </>
));

export const ServiceLogo = component$(({ service, large = false }: { service: ServiceCard; large?: boolean }) => (
  <span class={{ 'app-symbol': true, large }} aria-hidden="true">
    {service.logoUrl ? (
      <img src={service.logoUrl} alt="" loading="lazy" />
    ) : (
      serviceSymbols[service.id] ?? service.name.slice(0, 1)
    )}
  </span>
));

export const ProfileMenu = component$(
  ({
    image,
    open,
    username,
    onToggle$,
    onImageChange$,
    onImageClear$,
  }: {
    image: string;
    open: boolean;
    username: string;
    onToggle$: ToggleHandler;
    onImageChange$: ImageChangeHandler;
    onImageClear$: ToggleHandler;
  }) => (
    <div class="profile-menu">
      <button class="profile-trigger" type="button" aria-label="Open profile menu" aria-expanded={open} onClick$={onToggle$}>
        {image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}
      </button>
      {open && (
        <section class="profile-popover" aria-label="Profile menu">
          <div class="profile-summary">
            <div class="profile-preview">{image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}</div>
            <div>
              <h2>{username}</h2>
              <p>Homepage profile</p>
            </div>
          </div>
          <label class="profile-upload">
            Profile picture
            <input type="file" accept="image/*" onChange$={onImageChange$} />
          </label>
          {image && (
            <button class="profile-action" type="button" onClick$={onImageClear$}>
              Remove picture
            </button>
          )}
          <button class="profile-action" type="button" disabled>
            Preferences
          </button>
          <a class="profile-signout" href="/oauth2/sign_out?rd=/oauth2/start">
            Sign out
          </a>
        </section>
      )}
    </div>
  ),
);

export const ServiceTile = component$(({ service, onNavigate$ }: { service: ServiceCard; onNavigate$: NavigateHandler }) => {
  const detailUrl = service.id === 'sftp' ? '/uploads' : `/services/${encodeURIComponent(service.id)}`;
  const appUrl = service.url;
  const openDetail = $((event: Event) => {
    onNavigate$(detailUrl);
  });
  const openApp = $((event: Event) => {
    if (!appUrl.startsWith('/')) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    onNavigate$(appUrl);
  });
  const openDetailFromKeyboard = $((event: KeyboardEvent) => {
    if (event.key !== 'Enter' && event.key !== ' ') {
      return;
    }
    event.preventDefault();
    onNavigate$(detailUrl);
  });

  return (
    <article
      class="service-tile"
      role="link"
      tabIndex={0}
      aria-label={`${service.name} service information`}
      onClick$={openDetail}
      onKeyDown$={openDetailFromKeyboard}
    >
      <ServiceLogo service={service} />
      <div>
        <h3>
          <a
            href={detailUrl}
            onClick$={(event) => {
              event.preventDefault();
              event.stopPropagation();
              onNavigate$(detailUrl);
            }}
          >
            {service.name}
          </a>
        </h3>
        <p>{service.description}</p>
      </div>
      <div class="tile-actions">
        <a
          class="open-link"
          href={detailUrl}
          onClick$={(event) => {
            event.preventDefault();
            event.stopPropagation();
            onNavigate$(detailUrl);
          }}
        >
          Details
        </a>
        <a class="open-link app-link" href={appUrl} onClick$={(event) => (appUrl.startsWith('/') ? openApp(event) : event.stopPropagation())}>
          Open app
        </a>
      </div>
    </article>
  );
});

export const ServiceDetail = component$(
  ({
    service,
    phoneBackup,
    domain,
    username,
  }: {
    service: ServiceCard;
    phoneBackup?: PhoneBackupSetup;
    domain: string;
    username?: string;
  }) => {
    const displayUsername = username ?? '{username}';

    return (
      <article class="service-detail">
        <div class="service-detail-heading">
          <ServiceLogo service={service} large />
          <div>
            <h2>{service.name}</h2>
            {service.projectUrl && (
              <a class="project-link" href={service.projectUrl}>
                Project homepage
              </a>
            )}
          </div>
        </div>
        <p>{service.description}</p>
        <div class="detail-actions">
          <a class="primary-link" href={service.url}>
            {service.id === 'sftp' ? 'Open app' : 'Open app'}
          </a>
          {service.projectUrl && (
            <a class="secondary-link" href={service.projectUrl}>
              About project
            </a>
          )}
        </div>
        <dl class="info-list">
          <div>
            <dt>Open</dt>
            <dd>{service.id === 'sftp' ? `sftp://${displayUsername}@server.home.arpa:2222/` : service.url}</dd>
          </div>
          <div>
            <dt>Access</dt>
            <dd>{service.loginNotes}</dd>
          </div>
          {service.uploadNotes && (
            <div>
              <dt>Uploads</dt>
              <dd>{service.uploadNotes}</dd>
            </div>
          )}
        </dl>
        <section class="detail-block">
          <h3>Getting Started</h3>
          <ol class="steps">
            {(serviceTips[service.id] ?? ['Open the app once after access is granted so local account setup can finish.']).map((tip) => (
              <li key={tip}>{tip}</li>
            ))}
          </ol>
        </section>
        {service.id === 'backups' && <BackupSetup phoneBackup={phoneBackup} domain={domain} />}
        {service.id === 'sftp' && <SftpAccessInstructions username={displayUsername} />}
      </article>
    );
  }
);

export const BackupSetup = component$(({ phoneBackup, domain }: { phoneBackup?: PhoneBackupSetup; domain: string }) => {
  const setupPath = '/storage/emulated/0/NixHomeServerBackups';
  if (!phoneBackup?.enabled) {
    return (
      <section class="detail-block">
        <h3>Phone Backup Sync</h3>
        <p class="hint">Phone backup sync is not enabled in this server build.</p>
      </section>
    );
  }

  return (
    <section class="detail-block">
      <h3>Phone Backup Sync</h3>
      <p>
        The server publishes the encrypted phone-backup Kopia repository with Syncthing. Add the server to the phone,
        accept the shared folder as receive-only, and keep Syncthing running when the phone is on home LAN or Netbird.
      </p>
      <div class="qr-grid">
        {phoneBackup.serverDeviceId ? (
          <QrValue label="Server Device ID" value={phoneBackup.serverDeviceId} />
        ) : (
          <div class="qr-card unavailable">
            <h4>Server Device ID</h4>
            <p>{phoneBackup.serverDeviceIdError || 'The server device ID is not available yet.'}</p>
          </div>
        )}
        <QrValue label="Folder ID" value={phoneBackup.folderId} />
        {phoneBackup.connectionAddresses.map((address) => (
          <QrValue key={address} label={address.includes('100.') ? 'Netbird Address' : 'LAN Address'} value={address} />
        ))}
      </div>
      <dl class="info-list compact">
        <div>
          <dt>Phone Device Name</dt>
          <dd>{phoneBackup.deviceName}</dd>
        </div>
        {phoneBackup.configuredPhoneDeviceId && (
          <div>
            <dt>Configured Phone Device ID</dt>
            <dd>{phoneBackup.configuredPhoneDeviceId}</dd>
          </div>
        )}
        <div>
          <dt>Folder Label</dt>
          <dd>{phoneBackup.folderLabel}</dd>
        </div>
        <div>
          <dt>Suggested Phone Path</dt>
          <dd>{setupPath}</dd>
        </div>
        <div>
          <dt>Backup App</dt>
          <dd>https://backups.{domain}</dd>
        </div>
      </dl>
      <ol class="steps">
        <li>On the phone, install Syncthing-Fork or another Syncthing client and open its add-device screen.</li>
        <li>Scan the Server Device ID QR code or paste the Server Device ID. Use the LAN or Netbird address if discovery does not find the server.</li>
        <li>Confirm the phone Device ID matches the configured value above, then wait for the server to offer the folder.</li>
        <li>Accept the folder using the Folder ID above, choose receive-only on the phone, and store it at {setupPath} or another dedicated folder.</li>
        <li>Leave Syncthing running until the folder shows up to date. The files are encrypted Kopia repository data; restore through Kopia, not by opening those files directly.</li>
      </ol>
    </section>
  );
});

export const QrValue = component$(({ label, value }: { label: string; value: string }) => {
  const qrDataUrl = useSignal('');

  useVisibleTask$(async ({ track }) => {
    const text = track(() => value);
    qrDataUrl.value = await QRCode.toDataURL(text, {
      errorCorrectionLevel: 'M',
      margin: 1,
      width: 164,
    });
  });

  return (
    <div class="qr-card">
      <h4>{label}</h4>
      {qrDataUrl.value ? <img src={qrDataUrl.value} alt={`${label} QR code`} /> : <div class="qr-placeholder" aria-hidden="true" />}
      <code>{value}</code>
    </div>
  );
});

export const GuidePanel = component$(({ guide, username }: { guide: FolderGuide; username: string }) => {
  const personal = guide.personalPath?.replaceAll('{username}', username);
  return (
    <article class="guide-panel">
      <div>
        <span class={{ state: true, off: !guide.enabled }}>{guide.enabled ? 'Enabled' : 'Not enabled'}</span>
        <h2>{guide.title}</h2>
      </div>
      <p class="filetypes">{guide.fileTypes.join(', ')}</p>
      <dl>
        {personal && (
          <div>
            <dt>Personal</dt>
            <dd>{personal}</dd>
          </div>
        )}
        {guide.sharedPath && (
          <div>
            <dt>Shared</dt>
            <dd>{guide.sharedPath}</dd>
          </div>
        )}
      </dl>
      <ol class="steps">
        {guide.instructions.map((instruction) => (
          <li key={instruction}>{instruction}</li>
        ))}
      </ol>
    </article>
  );
});

export const SftpSetup = component$(({ username, domain }: { username: string; domain: string }) => (
  <article>
    <h2>Direct SFTP Setup</h2>
    <section class="detail-block">
      <h3>1) Generate an SFTP key pair</h3>
      <p>
        Create your key pair locally and keep the private key secure. If you want password-protected key access,
        set a passphrase during this key generation step.
      </p>
      <div class="accordion-list">
        <details class="accordion-card" open>
          <summary>Windows PowerShell</summary>
          <p>Create the .ssh folder first if it does not already exist.</p>
          <code>New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.ssh | Out-Null</code>
          <code>ssh-keygen -t ed25519 -a 64 -f $env:USERPROFILE\.ssh\nixhomeserver-files</code>
          <code>Get-Content $env:USERPROFILE\.ssh\nixhomeserver-files.pub</code>
        </details>
        <details class="accordion-card">
          <summary>macOS</summary>
          <code>mkdir -p ~/.ssh && chmod 700 ~/.ssh</code>
          <code>ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files</code>
          <code>cat ~/.ssh/nixhomeserver-files.pub</code>
        </details>
        <details class="accordion-card">
          <summary>Linux</summary>
          <code>mkdir -p ~/.ssh && chmod 700 ~/.ssh</code>
          <code>ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files</code>
          <code>cat ~/.ssh/nixhomeserver-files.pub</code>
        </details>
      </div>
      <p class="hint">
        After you copy the public key, return to this page and use <strong>Upload SFTP Public Key</strong> to register it.
      </p>
    </section>
    <section class="detail-block">
      <h3>2) Connect with a file explorer or client</h3>
      <p>Use one of these options after the key is uploaded.</p>
      <SftpAccessInstructions username={username} />
    </section>
    <p class="hint">Browser uploads still work at https://files.{domain}; SFTP is for larger or repeated transfers.</p>
  </article>
));

export const SftpAccessInstructions = component$(({ username }: { username: string }) => (
  <div class="accordion-list">
    <details class="accordion-card" open>
      <summary>Windows</summary>
      <p>Use WinSCP with these settings:</p>
      <dl class="info-list compact">
        <div>
          <dt>Protocol</dt>
          <dd>SFTP</dd>
        </div>
        <div>
          <dt>Host</dt>
          <dd>server.home.arpa</dd>
        </div>
        <div>
          <dt>Port</dt>
          <dd>2222</dd>
        </div>
        <div>
          <dt>Username</dt>
          <dd>{username}</dd>
        </div>
        <div>
          <dt>Private key</dt>
          <dd>$env:USERPROFILE\.ssh\nixhomeserver-files</dd>
        </div>
      </dl>
    </details>
    <details class="accordion-card">
      <summary>macOS</summary>
      <p>In Finder, choose Go &gt; Connect to Server, then enter:</p>
      <code>sftp://{username}@server.home.arpa:2222/</code>
      <p>When prompted, select the private key that matches the public key you uploaded.</p>
    </details>
    <details class="accordion-card">
      <summary>Linux (Nemo)</summary>
      <p>In Nemo, choose File &gt; Connect to Server, then use:</p>
      <code>sftp://{username}@server.home.arpa:2222/</code>
      <p>When prompted, select the private key that matches the public key you uploaded.</p>
    </details>
  </div>
));
