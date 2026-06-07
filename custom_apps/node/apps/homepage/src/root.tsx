import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { FolderGuide, HomepageData, ServiceCard, SftpKeyResponse } from './shared/types.js';
import './client/styles.css';

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
};

export default component$(() => {
  const data = useSignal<HomepageData | undefined>();
  const error = useSignal('');
  const selectedService = useSignal<ServiceCard | undefined>();
  const path = useSignal('/');
  const activeGuide = useSignal('documents');
  const publicKey = useSignal('');
  const keyStatus = useSignal('');
  const keySubmitting = useSignal(false);

  useVisibleTask$(() => {
    path.value = window.location.pathname;
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

  const submitKey = $(async () => {
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
      if (!response.ok) {
        throw new Error(body.error || 'Public key could not be saved');
      }
      publicKey.value = '';
      keyStatus.value = body.message || 'SFTP public key saved.';
    } catch (caught) {
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
  const domain = data.value?.domain ?? 'sydneybasiniot.org';

  return (
    <main class="shell">
      <header class="topbar">
        <div>
          <p class="eyebrow">Sydney Basin Services</p>
          <h1>{isUploads ? 'How to Upload Files' : 'Home'}</h1>
        </div>
        <div class="session">
          <span>{user?.username ?? 'Loading'}</span>
          <a href="/oauth2/sign_out?rd=/oauth2/start">Sign out</a>
        </div>
      </header>

      {error.value && <p class="notice">{error.value}</p>}

      <nav class="tabs" aria-label="Homepage sections">
        <a class={{ selected: !isUploads }} href="/">
          Services
        </a>
        <a class={{ selected: isUploads }} href="/uploads">
          How to Upload Files
        </a>
      </nav>

      {!isUploads && (
        <>
          <section class="section">
            <div class="section-heading">
              <h2>Services</h2>
              <p>Open the apps enabled in this server build.</p>
            </div>
            <div class="service-grid">
              {enabledServices.map((service) => (
                <ServiceTile key={service.id} service={service} onSettings$={() => (selectedService.value = service)} />
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
                <button
                  key={item.id}
                  class={{ selected: activeGuide.value === item.id }}
                  type="button"
                  onClick$={() => (activeGuide.value = item.id)}
                >
                  <span>{item.title}</span>
                  <small>{item.enabled ? 'Enabled' : 'Not enabled'}</small>
                </button>
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
              {keyStatus.value && <p class="key-status">{keyStatus.value}</p>}
            </form>
          </section>

          <section class="section">
            <div class="section-heading">
              <h2>Server Bootstrap</h2>
              <p>Operator checklist for a new host or a routine guarded deploy.</p>
            </div>
            <ol class="admin-steps">
              {(data.value?.adminGuide ?? []).map((step) => (
                <li key={step.title}>
                  <h3>{step.title}</h3>
                  <p>{step.detail}</p>
                  {step.command && <code>{step.command}</code>}
                </li>
              ))}
            </ol>
          </section>
        </>
      )}

      {selectedService.value && (
        <ServiceDialog service={selectedService.value} onClose$={() => (selectedService.value = undefined)} />
      )}
    </main>
  );
});

export const ServiceTile = component$(
  ({ service, onSettings$ }: { service: ServiceCard; onSettings$: () => void }) => (
    <article class="service-tile">
      <span class="app-symbol" aria-hidden="true">
        {serviceSymbols[service.id] ?? service.name.slice(0, 1)}
      </span>
      <div>
        <h3>
          <a href={service.url}>{service.name}</a>
        </h3>
        <p>{service.description}</p>
      </div>
      <div class="tile-actions">
        <a class="open-link" href={service.url}>
          Open
        </a>
        <button class="settings-button" type="button" aria-label={`Settings for ${service.name}`} onClick$={onSettings$}>
          <span aria-hidden="true">&#9881;</span>
        </button>
      </div>
    </article>
  ),
);

export const ServiceDialog = component$(({ service, onClose$ }: { service: ServiceCard; onClose$: () => void }) => (
  <div class="modal-backdrop" role="presentation" onClick$={onClose$}>
    <section class="modal" role="dialog" aria-modal="true" aria-labelledby="service-dialog-title" onClick$={(event) => event.stopPropagation()}>
      <button class="modal-close" type="button" aria-label="Close dialog" onClick$={onClose$}>
        x
      </button>
      <span class="app-symbol large" aria-hidden="true">
        {serviceSymbols[service.id] ?? service.name.slice(0, 1)}
      </span>
      <h2 id="service-dialog-title">{service.name}</h2>
      <p>{service.description}</p>
      <dl>
        <div>
          <dt>Open</dt>
          <dd>{service.url}</dd>
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
      <h3>Tips</h3>
      <ol class="steps">
        {(serviceTips[service.id] ?? ['Open the app once after access is granted so local account setup can finish.']).map((tip) => (
          <li key={tip}>{tip}</li>
        ))}
      </ol>
    </section>
  </div>
));

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
    <p>Generate a key on your device, save the public key here, then connect to the dedicated files SFTP port.</p>
    <div class="command-grid">
      <div>
        <h3>macOS / Linux</h3>
        <code>ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files</code>
        <code>cat ~/.ssh/nixhomeserver-files.pub</code>
        <code>sftp -P 2222 -i ~/.ssh/nixhomeserver-files {username}@server.home.arpa</code>
      </div>
      <div>
        <h3>Windows PowerShell</h3>
        <code>ssh-keygen -t ed25519 -a 64 -f $env:USERPROFILE\.ssh\nixhomeserver-files</code>
        <code>Get-Content $env:USERPROFILE\.ssh\nixhomeserver-files.pub</code>
        <code>sftp -P 2222 -i $env:USERPROFILE\.ssh\nixhomeserver-files {username}@server.home.arpa</code>
      </div>
      <div>
        <h3>File Browser</h3>
        <code>sftp://{username}@server.home.arpa:2222/</code>
        <p>When prompted, select the private key that matches the public key you uploaded.</p>
      </div>
    </div>
    <p class="hint">Browser uploads still work at https://files.{domain}; SFTP is for larger or repeated transfers.</p>
  </article>
));
